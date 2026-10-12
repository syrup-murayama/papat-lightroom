-- Metadata panel preset "papat": where each photo was sent.
local id = 'app.papat.lightroom.'
return {
  title = 'papat',
  id = 'papatTagset',
  items = {
    'com.adobe.filename',
    'com.adobe.separator',
    id .. 'papatSid',
    id .. 'papatFilename',
  },
}
