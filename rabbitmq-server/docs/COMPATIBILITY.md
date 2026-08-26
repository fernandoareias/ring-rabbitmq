# Maintaining `compatibility.json`

This document describes how `docs/compatibility.json` was built and how it
should be maintained going forward.

## Purpose

`compatibility.json` is a machine-readable compatibility matrix that maps each
RabbitMQ release version to its supported Erlang/OTP and Elixir version ranges.
It uses mathematical interval notation familiar to Maven and NuGet users.

See [GitHub Discussion #15438](https://github.com/rabbitmq/rabbitmq-server/discussions/15438)
for the original proposal.

## File Format

The file is a JSON object keyed by RabbitMQ version string, ordered
newest-first. Each value contains `erlang` and `elixir` keys with version
ranges in interval notation:

```json
{
  "4.2.4": {
    "erlang": "[26.2,28.0)",
    "elixir": "[1.13.4,1.20.0)"
  }
}
```

`[` means inclusive, `)` means exclusive. For example, `[26.2,28.0)` means
`26.2 <= version < 28.0`.

## Scope

The file covers RabbitMQ 3.11.0 onwards. Earlier releases are not included.

Only final releases are included. Betas, release candidates, and alphas are
excluded.

## Data Sources

### Erlang Version Ranges

The Erlang minimum and maximum version for each RabbitMQ release come from the compatibility
table in the RabbitMQ website repository at `docs/which-erlang.md`:

https://github.com/rabbitmq/rabbitmq-website/blob/main/docs/which-erlang.md

That file contains two HTML tables (supported and unsupported series) with
columns for RabbitMQ versions, minimum required Erlang/OTP, and maximum
supported Erlang/OTP.

To convert the HTML table values to interval notation:

- The minimum becomes the inclusive lower bound
- The maximum `X.Y.x` becomes the exclusive upper bound `X.(Y+1)`
- Example: min `26.2`, max `27.x` becomes `[26.2,28.0)`
- Example: min `25.0`, max `26.2.x` becomes `[25.0,26.3)`
- Example: min `25.0`, max `25.3.x` becomes `[25.0,25.4)`

Preserve the precision from the HTML table. If the table says `24.3.4.8`, use
that exact value in the interval.

When a release exists in the git tags but is not explicitly listed in the HTML
table, assign it the same Erlang range as its siblings in the same release
series and compatibility group.

### Elixir Version Ranges

The Elixir range for each release comes from the `elixir` field in
`deps/rabbitmq_cli/mix.exs` at the corresponding git tag.

To extract the Elixir constraint for a release:

```bash
git show v4.2.4:deps/rabbitmq_cli/mix.exs | grep -oP 'elixir:\s*"\K[^"]+'
```

This returns a string like `>= 1.13.4 and < 1.20.0`, which converts to
interval notation as `[1.13.4,1.20.0)`.

To extract all Elixir constraints at once:

```bash
for tag in $(git tag -l 'v3.11.*' 'v3.12.*' 'v3.13.*' 'v4.*' \
    | grep -v -E '(beta|rc|alpha)' | sort -V); do
  elixir=$(git show "$tag:deps/rabbitmq_cli/mix.exs" 2>/dev/null \
    | grep -oP 'elixir:\s*"\K[^"]+')
  echo "$tag: $elixir"
done
```

## Adding a New Release

When a new RabbitMQ version is released:

1. Determine the Erlang range from `docs/which-erlang.md` in the website
   repository, or from the release notes if the website has not been updated
   yet. If neither source has been updated, use the same Erlang range as the
   previous release in the same series, and update it later when the
   authoritative data is available
2. Extract the Elixir constraint from `deps/rabbitmq_cli/mix.exs` at the new
   release tag
3. Add the new entry at the top of the JSON object (newest-first ordering)
4. Validate the file is well-formed: `jq . docs/compatibility.json > /dev/null`
5. Verify the entry count matches the number of release tags:
   `jq 'keys | length' docs/compatibility.json`

## Relationship to Other Files

`docs/compatibility.json` is separate from `.github/versions.json`. The
`versions.json` file lists RabbitMQ and Erlang versions for populating GitHub
Discussions template dropdowns and is auto-updated by
`.github/scripts/update-versions.sh`. It serves a different purpose and should
not be combined with the compatibility matrix.
