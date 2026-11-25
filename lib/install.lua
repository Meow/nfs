--- Installer of the NFS package: sends Nighty's Fast Serializer to clients and loads it into the
-- `NFS` global.

--- Returns the major version of a version string such as '8.0.0'.
-- @param version [String version, or any value]
-- @return [String major version, or nil]
local function major(version)
  return tostring(version):match('^%d+')
end

--- Called by the Package manager once the package has been included. An `NFS` of the same major
-- version is kept, since releases within one encode identically: a code refresh keeps the loaded
-- library with its custom types, and a server whose `lua_shared` has NFS built in keeps that one.
function PACKAGE:__installed__()
  AddCSLuaFile(self.__path__..'lib/nfs.lua')

  if !NFS or major(NFS.VERSION) != major(self.metadata.version) then
    NFS = include(self.__path__..'lib/nfs.lua')
  end
end
