$ErrorActionPreference = 'Stop'
$packageArgs = @{
  packageName    = 'venera-unified'
  url64bit       = 'https://github.com/ACGNnsj/venera-unified/releases/download/v1.20.0/VeneraUnified-1.20.0-windows.zip'
  checksum64     = '4ac057250ebf4e17759ce399ddd10dbcbca8a5a6524cbf02d4df957cb5489125'
  checksumType64 = 'sha256'
  unziplocation  = "$(Split-Path -Parent $MyInvocation.MyCommand.Definition)"
}
Install-ChocolateyZipPackage @packageArgs
