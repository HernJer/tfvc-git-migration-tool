# Contributing to tfvc2git

Thank you for your interest in contributing! We welcome bug reports, feature requests, and pull requests.

## Issues and Bug Reports
Please use the provided issue templates when submitting bugs or feature requests. Be sure to include:
- A clear description of the problem
- Steps to reproduce
- Relevant log output (with sensitive info scrubbed!)
- The version of tfvc2git and Azure DevOps Server you are using

## Pull Requests
1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Write tests for your changes (we use Pester)
4. Ensure all existing tests pass (`./build/Build.ps1 -Test`)
5. Submit a Pull Request

## Development Setup
This project uses standard PowerShell module conventions.
- Tests are written using [Pester](https://github.com/pester/Pester)
- The build script is located at `./build/Build.ps1`
