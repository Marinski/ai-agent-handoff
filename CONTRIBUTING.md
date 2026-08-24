# Contributing to ai-agent-handoff

Thank you for wanting to contribute! This project helps AI agents hand off conversation context between different tools.

## Development Setup

1. **Fork the repository** on GitHub
2. **Clone your fork** locally:
   ```bash
   git clone git@github.com:YOUR-USERNAME/ai-agent-handoff.git
   cd ai-agent-handoff
   ```
3. **Create a branch** for your feature/fix:
   ```bash
   git checkout -b feature/your-feature-name
   ```
4. **Make your changes** and test them
5. **Commit your changes** with a clear message
6. **Push to your fork** and open a Pull Request

## Guidelines

- Follow the existing code style (bash scripts, jq filters, sed patterns)
- Ensure jq filters handle edge cases (empty arrays, missing fields)
- Update the README if adding new features or changing usage
- Update the CHANGELOG.md for user-visible changes
- Test with actual Claude session JSONL files
- Keep the script POSIX-compatible where possible

## Pull Request Process

1. Update the README with any new usage information
2. Update CHANGELOG.md with a summary of changes
3. Ensure all jq filters are robust (test with `jq -r` on sample data)
4. The maintainer will review and merge

## Report Bugs / Feature Requests

- Open an issue on GitHub with a clear description
- Include a sample Claude session JSONL if relevant
- Describe the handoff scenario (source → target tool)