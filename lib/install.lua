--- Installer of the NFS package: sends Nighty's Fast Serializer to clients and loads it into the
-- `NFS` global.

--- Called by the Package manager once the package has been included. A code refresh keeps the
-- loaded library, and with it the custom types added to it.
function PACKAGE:__installed__()
  AddCSLuaFile(self.__path__..'lib/nfs.lua')

  if !NFS then
    NFS = include(self.__path__..'lib/nfs.lua')
  end
end
