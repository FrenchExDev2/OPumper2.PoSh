@{
    # The validated PowerShell. To upgrade, change Version and both checksums from the release's hashes.sha256.
    # Linux images download powershell-<Version>-linux-musl-x64.tar.gz in test/Containerfile.
    Stable = @{
        Version = '7.6.7'
        LinuxMuslSHA256 = 'D74A1B7E1D1FBF150AE6F29E083953CE07FC833FE9D66218D54940A8638249C6'
        WindowsUri = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.7/PowerShell-7.6.7-win-x64.zip'
        WindowsSHA256 = 'D2F952EBDBF24386CB8923553AA58E41A846DB35A6155EA04C58142A4B16DBB7'
    }
}
