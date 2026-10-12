-- papat's own plug-in fields. They record which gallery a photo was sent to so
-- the client's result can be matched back. They are separate from the
-- photographer's metadata (rating, flag, label, caption, keywords stay untouched).
return {
  schemaVersion = 1,
  metadataFieldsForPhotos = {
    { id = 'papatSourceId', title = 'papat 写真ID', dataType = 'string', readOnly = true, searchable = false, browsable = false },
    { id = 'papatSid', title = 'papat ギャラリー', dataType = 'string', readOnly = true, searchable = true, browsable = true },
    { id = 'papatFilename', title = 'papat 送信ファイル名', dataType = 'string', readOnly = true, searchable = true, browsable = false },
  },
}
