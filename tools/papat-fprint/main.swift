// papat-fprint — macOS-only helper bundled with the plug-in (papat.lrplugin/bin/papat-fprint).
//
// Groups photos that look alike, refining the time-based groups the plug-in already computed
// (lib/grouping.lua, a port of the gallery's own `autoGroups`). Design: docs/grouping-design-v0.1.md
// 第2部 §2.2, §2.10 ("③ 時刻で切って、似ているかで直す") in the papat site repo. Built from
// tools/similarity-experiment/fprint.swift (same repo, a spike that measured this approach on a
// real 296-photo shoot before 1.2.0 was commissioned — see §2.10 there for the numbers).
//
// What it does, in order:
//   1. Read <input.json>: { "photos": ["/tmp/.../0001.jpg", ...], "timeGroups": [1,1,2,...] }
//      (same order and length; timeGroups is lib/grouping.lua's own output — 0 = no capture time).
//   2. For every photo, ask Vision for an image feature print (VNGenerateImageFeaturePrintRequest;
//      on-device, no network — only Foundation / ImageIO / Vision are imported, nothing that could
//      make a request is ever called, so there is nothing to disable or sandbox).
//   3. Within each run of photos that share one time-group number, look for a place the picture
//      changes sharply (the windowed distance peaks, §2.10's "前後3枚の平均"), and split there, never
//      smaller than two photos a side. Existing time-group boundaries are never removed ("つなぐ"
//      is not implemented — see the design doc's §2.10 note on why not yet).
//   4. Write <output.json>: { "groups": [1,1,2,3,...] } (1-based, same order; 0 passes through
//      for photos with no capture time). Exit 0 only on success; the caller (lib/similarity.lua)
//      must ignore the output file whenever the exit code is not 0 — on any error this process
//      tries to leave the previous file alone rather than write a half-finished answer.
//
// No photo, feature print, or distance is written anywhere but <output.json>'s group numbers;
// nothing here keeps state between runs.

import Foundation
import Vision

// ---------------------------------------------------------------------------
// Constants (docs/grouping-design-v0.1.md §2.10's "1.2.0 で作るときの調整の見立て"; the task that
// commissioned this file calls all of these provisional — they are tuned on one shoot so far).
// ---------------------------------------------------------------------------

let WINDOW = 3          // "前後3枚の平均": photos averaged on each side of a candidate cut
let PEAK_RADIUS = 2     // a candidate must be the largest change within this many neighbours
let MIN_GROUP_SIZE = 2  // a similarity cut never leaves fewer photos than this on either side
let MIN_CUTS_FOR_STATS = 3     // existing time-cuts needed before trusting their own dissimilarity
let T_SPLIT_DEFAULT: Float = 0.54  // §2.10's experiment found roughly 0.541 on one shoot
let T_SPLIT_FLOOR: Float = 0.45    // lower bound: guards against over-splitting when stats are thin
let T_SPLIT_CEIL: Float = 0.62     // upper bound: guards against under-splitting when stats are thin

// ---------------------------------------------------------------------------
// I/O
// ---------------------------------------------------------------------------

func fail(_ message: String) -> Never {
  FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
  exit(1)
}

let args = CommandLine.arguments
guard args.count == 3 else { fail("usage: papat-fprint <input.json> <output.json>") }
let inputPath = args[1]
let outputPath = args[2]

guard let inputData = FileManager.default.contents(atPath: inputPath) else {
  fail("could not read \(inputPath)")
}
guard let inputObj = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any] else {
  fail("\(inputPath) is not a JSON object")
}
guard let photoPaths = inputObj["photos"] as? [String] else { fail("\"photos\" missing or not an array of strings") }
guard let timeGroupsRaw = inputObj["timeGroups"] as? [Any] else { fail("\"timeGroups\" missing or not an array") }

let n = photoPaths.count
guard timeGroupsRaw.count == n else { fail("photos (\(n)) and timeGroups (\(timeGroupsRaw.count)) differ in length") }
let timeGroups: [Int] = timeGroupsRaw.map { ($0 as? NSNumber)?.intValue ?? 0 }

func writeGroups(_ groups: [Int]) {
  let obj: [String: Any] = ["groups": groups]
  guard let data = try? JSONSerialization.data(withJSONObject: obj) else { fail("could not encode the result") }
  do {
    try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
  } catch {
    fail("could not write \(outputPath): \(error)")
  }
}

if n == 0 {
  writeGroups([])
  exit(0)
}

// ---------------------------------------------------------------------------
// 1. Feature prints (one Vision request per photo; a photo that fails just has no vector)
// ---------------------------------------------------------------------------

var vectors = [[Float]](repeating: [], count: n)
var dims = -1

for i in 0..<n {
  let url = URL(fileURLWithPath: photoPaths[i])
  let request = VNGenerateImageFeaturePrintRequest()
  let handler = VNImageRequestHandler(url: url, options: [:])
  do {
    try handler.perform([request])
    guard let observation = request.results?.first else { continue }
    var floats: [Float] = []
    if observation.elementType == .float {
      floats = observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    } else if observation.elementType == .double {
      let doubles = observation.data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
      floats = doubles.map { Float($0) }
    } else {
      continue
    }
    if floats.isEmpty { continue }
    vectors[i] = floats
    if dims < 0 { dims = floats.count }
  } catch {
    continue // this photo's vector stays empty: treated the same as "no capture time" below
  }
}

// A vector counts only when it is the shared dimension and its photo has a capture time: the
// windowed average must never silently mix in an undated photo's picture.
func usableVector(_ i: Int) -> Bool {
  return timeGroups[i] > 0 && dims > 0 && vectors[i].count == dims
}

let anyUsable = (0..<n).contains { usableVector($0) }
let anyDated = timeGroups.contains { $0 > 0 }
if anyDated && !anyUsable {
  // every dated photo's feature print failed: something is wrong with this run (Vision
  // unavailable, unreadable files, …), not just one bad photo. Fail outright rather than
  // guess; the caller falls back to the time groups it already has.
  fail("no usable feature print among \(n) photos (dims=\(dims))")
}

// ---------------------------------------------------------------------------
// 2. Windowed dissimilarity between every adjacent pair (0-indexed k: between photo k, k+1)
// ---------------------------------------------------------------------------

func normalized(_ v: [Float]) -> [Float] {
  var sumSquares: Float = 0
  for x in v { sumSquares += x * x }
  let norm = sqrtf(sumSquares)
  if norm <= 0 { return v }
  return v.map { $0 / norm }
}

func meanVector(_ vs: [[Float]]) -> [Float]? {
  guard let width = vs.first?.count, width > 0 else { return nil }
  var sum = [Float](repeating: 0, count: width)
  for v in vs { for i in 0..<width { sum[i] += v[i] } }
  let count = Float(vs.count)
  return sum.map { $0 / count }
}

func distance(_ a: [Float], _ b: [Float]) -> Float {
  var sumSquares: Float = 0
  let width = min(a.count, b.count)
  for i in 0..<width {
    let d = a[i] - b[i]
    sumSquares += d * d
  }
  return sqrtf(sumSquares)
}

var D = [Float](repeating: 0, count: max(0, n - 1))
for k in 0..<D.count {
  let loLeft = max(0, k - WINDOW + 1)
  var left: [[Float]] = []
  for i in loLeft...k where usableVector(i) { left.append(vectors[i]) }
  let hiRight = min(n - 1, k + WINDOW)
  var right: [[Float]] = []
  for j in (k + 1)...hiRight where usableVector(j) { right.append(vectors[j]) }
  guard let a = meanVector(left), let b = meanVector(right) else { continue } // D[k] stays 0: no cut proposed
  D[k] = distance(normalized(a), normalized(b))
}

// ---------------------------------------------------------------------------
// 3. Runs of one time-group (maximal; only photos with a capture time take part)
// ---------------------------------------------------------------------------

struct Run { let lo: Int; let hi: Int; let timeGroup: Int }

var runs: [Run] = []
do {
  var i = 0
  while i < n {
    if timeGroups[i] <= 0 { i += 1; continue }
    var j = i
    while j + 1 < n && timeGroups[j + 1] == timeGroups[i] { j += 1 }
    runs.append(Run(lo: i, hi: j, timeGroup: timeGroups[i]))
    i = j + 1
  }
}

// §2.10's "線の下限・上限": the split threshold is normally the median dissimilarity at the
// gallery's own existing time-cuts (back-to-back runs with nothing undated between them), the
// same "時刻を先生役にする" idea as the design's experiment — but clamped, and replaced by a
// fixed default, when there are too few of them to trust (a shoot with very few time-cuts).
var cutDistances: [Float] = []
for m in 0..<max(0, runs.count - 1) {
  if runs[m].hi + 1 == runs[m + 1].lo { cutDistances.append(D[runs[m].hi]) }
}

var tSplit = T_SPLIT_DEFAULT
if cutDistances.count >= MIN_CUTS_FOR_STATS {
  let sorted = cutDistances.sorted()
  let mid = sorted.count / 2
  let median = sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
  tSplit = min(T_SPLIT_CEIL, max(T_SPLIT_FLOOR, median))
}

func isPeak(_ k: Int) -> Bool {
  let lo = max(0, k - PEAK_RADIUS)
  let hi = min(D.count - 1, k + PEAK_RADIUS)
  for idx in lo...hi where D[idx] > D[k] { return false }
  return true
}

// ---------------------------------------------------------------------------
// 4. Within each run: candidate cuts (peaks at or above the threshold), accepted strongest
//    first, never leaving fewer than MIN_GROUP_SIZE photos on either side. No merging across
//    an existing time-cut ("つなぐ" — not in this version; see docs/grouping-design-v0.1.md §2.10).
// ---------------------------------------------------------------------------

var cutsAt = Set<Int>() // k values (0-indexed, between photo k and k+1)
for run in runs {
  guard run.hi > run.lo else { continue } // one photo: nothing to split
  var candidates: [Int] = []
  for k in run.lo...(run.hi - 1) where isPeak(k) && D[k] >= tSplit {
    candidates.append(k)
  }
  let strongestFirst = candidates.sorted { D[$0] > D[$1] }
  var accepted: [Int] = []
  for k in strongestFirst {
    var edges = [run.lo - 1] + accepted.filter { $0 > run.lo - 1 && $0 < run.hi } + [run.hi]
    edges.sort()
    guard let prevEdge = edges.last(where: { $0 < k }), let nextEdge = edges.first(where: { $0 >= k }) else { continue }
    if (k - prevEdge) >= MIN_GROUP_SIZE && (nextEdge - k) >= MIN_GROUP_SIZE {
      accepted.append(k)
    }
  }
  for k in accepted { cutsAt.insert(k) }
}

// ---------------------------------------------------------------------------
// 5. Final 1-based group numbers, in the given order (0 passes through for undated photos)
// ---------------------------------------------------------------------------

var groups = [Int](repeating: 0, count: n)
var g = 0
for i in 0..<n {
  if timeGroups[i] <= 0 { continue }
  if g == 0 {
    g = 1
  } else {
    let previousDated = timeGroups[i - 1] > 0
    if !previousDated || timeGroups[i] != timeGroups[i - 1] || cutsAt.contains(i - 1) {
      g += 1
    }
  }
  groups[i] = g
}

writeGroups(groups)
