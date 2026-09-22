@{
    Tracks = @{
        default = @{
            SourceBuildRequirementMap = @{
                default = @('setuptools', 'wheel')
                pycuda = @('setuptools', 'wheel', 'oldest-supported-numpy')
            }
            LockExcludePackages = @()
        }
        api = @{
            LockExcludePackages = @()
        }
        cu11 = @{
            LockExcludePackages = @('setuptools', 'wheel', 'oldest-supported-numpy')
        }
        cu12 = @{
            LockExcludePackages = @('setuptools', 'wheel', 'oldest-supported-numpy')
        }
    }
}