Package:describe(function(s)
  s.id          = 'nfs'
  s.name        = 'Nighty\'s Fast Serializer'
  s.version     = '8.0.0'
  s.date        = '2026-11-18'
  s.summary     = 'A fast binary serializer for Garry\'s Mod.'
  s.description = 'Encodes Lua values, entities, vectors, angles, matrices and colors into compact binary '..
                  'strings and decodes them back. A continuation of Srlion\'s Fast Serializer.'
  s.authors     = { 'Srlion', 'Nighty' }
  s.file        = 'lib/install.lua'
  s.website     = 'https://github.com/Meow/nfs'
  s.license     = 'MIT'

  add_client_env('NFS_PATH', PACKAGE.__path__)
end)
