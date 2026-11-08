$ErrorActionPreference = 'Stop'
$packageArgs = @{
  packageName    = 'venera-unified'
  url64bit       = 'https://github.com/ACGNnsj/venera-unified/releases/download/v1.21.0/VeneraUnified-1.21.0-windows.zip'
  checksum64     = 'dd496b6a58f4ea00d77c024b6bf544036ea11b3f140468b73f887232f2ab9318'
  checksumType64 = 'sha256'
  unziplocation  = "$(Split-Path -Parent $MyInvocation.MyCommand.Definition)"
}
Install-ChocolateyZipPackage @packageArgs
