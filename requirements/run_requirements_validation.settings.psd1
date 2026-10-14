@{
    Tracks = @{
        default = @{
            SourceBuildRequirementMap = @{
                default = @(
                    'setuptools==75.8.2',
                    'wheel==0.45.1'
                )
                pycuda = @(
                    'setuptools==75.8.2',
                    'wheel==0.45.1',
                    'oldest-supported-numpy==2023.12.21'
                )
            }
            LockExcludePackages = @(
                'setuptools',
                'wheel',
                'oldest-supported-numpy'
            )
        }
    }
}