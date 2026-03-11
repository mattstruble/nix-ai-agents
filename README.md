# nix-ai-agents

A Nix flake that manages AI coding agent configuration via Home Manager:
skills aggregation, config file generation, and shared MCP server definitions.

## Features

- **Skills aggregation** -- Merge skills from multiple repositories into a
  single directory, deployed to each enabled agent's config path.
- **Config generation** -- Generate agent config files (e.g., `opencode.json`)
  from Nix with per-host overrides through the module system.
- **Shared MCP servers** -- Define MCP servers once, automatically inject into
  all enabled agents. Per-agent overrides on name collision.
- **AGENTS.md management** -- Deploy agent instruction files from a source
  path or inline text.

## Agent Support

| Agent | Skills Path | Config File | Status |
|---|---|---|---|
| `opencode` | `~/.config/opencode/skills/` | `opencode.json` | Implemented |
| `claude` | `~/.claude/skills/` | -- | Skills only |
| `cursor` | `~/.cursor/skills/` | -- | Skills only |

## Installation

Add `nix-ai-agents` to your flake inputs:

```nix
# flake.nix
{
  inputs = {
    ai-agents.url = "github:mattstruble/nix-ai-agents";

    # Skills repositories as flake inputs (pinned via flake.lock)
    skills-core = {
      url = "github:<repo>/skills";
      flake = false;
    };
  };
}
```

Then import the Home Manager module and configure it:

```nix
# home.nix
{ inputs, config, ... }:

let
  mkLink = config.lib.file.mkOutOfStoreSymlink;
in
{
  imports = [ inputs.ai-agents.homeManagerModules.default ];

  programs.ai-agents = {
    enable = true;
    agents = [ "opencode" ];

    skills = [
      inputs.skills-core
    ];

    # Shared MCP servers -- injected into all enabled agents
    mcpServers = {
      context7 = {
        type = "remote";
        url = "https://mcp.context7.mcp";
      };
      filesystem = {
        command = "npx";
        args = [ "@modelcontextprotocol/server-filesystem" "/home" ];
      };
    };

    # OpenCode-specific configuration
    opencode = {
      agentsFile = mkLink "/path/to/AGENTS.md";
      config = {
        "$schema" = "https://opencode.ai/config.json";
        permission = {
          bash."*" = "ask";
          edit = "allow";
          read = "allow";
        };
        # Agent-specific MCPs (merged with shared, wins on name collision)
        # mcp.opencode-only-tool = { type = "stdio"; command = "..."; };
      };
    };
  };
}
```

### Per-Host Overrides

The `opencode.config` option uses `pkgs.formats.json` which deep-merges
through the Nix module system. Define shared config in your base `home.nix`
and add host-specific overrides in per-host configs:

```nix
# hosts/work-machine/home.nix
{
  programs.ai-agents.opencode.config = {
    provider.default = "bedrock";
    mcp.internal-tool = {
      command = "internal-mcp";
      args = [ "--endpoint" "https://internal.corp" ];
    };
  };
}
```

The module system merges this with the shared config automatically.

## Skills Sources

Skills can be provided as either **flake inputs** or **git sources**.

### Flake Inputs

Add the skills repo as a `flake = false` input and reference it directly.
Versions are pinned automatically via `flake.lock`.

```nix
# flake.nix
inputs.skills-core = {
  url = "github:<repo>/skills";
  flake = false;
};

# home.nix
programs.ai-agents.skills = [ inputs.skills-core ];
```

### Git Sources

Specify a git URL directly in the module config. Git source entries are
**cloned at Home Manager activation time** as the current user, so they
have access to SSH keys and git credential helpers. This makes them
suitable for private repositories that the nix daemon cannot access.

A bare URL string is shorthand for `{ source = "..."; }`:

```nix
programs.ai-agents.skills = [
  inputs.skills-core

  # Bare URL string (shorthand)
  "https://github.com/me/my-skills"

  # Attrset with ref pinning
  {
    source = "https://github.com/me/my-skills";
    ref = "v1.0.0";
  }

  # SSH URL
  {
    source = "git@github.com:corp/internal-skills.git";
    ref = "main";
  }
];
```

**Git source options:**

| Field | Required | Description |
|---|---|---|
| `source` | Yes | Git URL (HTTPS or SSH), path, or derivation |
| `ref` | No | Branch or tag name (git sources only) |
| `rev` | No | Exact commit SHA (git sources only) |
| `include` | No | List of skill names to deploy (whitelist). Mutually exclusive with `exclude`. |
| `exclude` | No | List of skill names to skip (blacklist). Mutually exclusive with `include`. |

Cloned repos are cached in `~/.cache/nix-ai-agent-skills/repos/` and
updated on each activation.

### Precedence

Git-source skills are deployed **after** store skills (flake inputs/paths).
On name collision, **git skills override store skills**. Within each
group, later entries override earlier ones. Filtering (via `include` or
`exclude`) happens before deployment, not after.

### Filtering Skills

Each skills entry can optionally specify an `include` list (whitelist) or
an `exclude` list (blacklist) to control which discovered skills get
deployed. These are mutually exclusive -- specifying both is an error.

Skill names correspond to the directory name containing the `SKILL.md` file.

```nix
programs.ai-agents.skills = [
  # Deploy only specific skills from a flake input
  {
    source = inputs.skills-core;
    include = [ "git-commit" "test-design" ];
  }

  # Deploy all skills except a few from a git source
  {
    source = "https://github.com/me/my-skills";
    exclude = [ "deprecated-skill" "experimental" ];
  }

  # No filtering (deploy everything) -- these are equivalent:
  inputs.other-skills
  "https://github.com/org/more-skills"
  { source = inputs.yet-more-skills; }
];
```

**Edge cases:**

- `include = []` -- empty whitelist matches nothing; no skills deployed
  from that source.
- `exclude = []` -- empty blacklist excludes nothing; all skills deployed.
- A nonexistent skill name in `include` or `exclude` is silently ignored.

## How Skills Merging Works

1. **Discovery** -- Each skills source is scanned recursively for `SKILL.md`
   files at any depth. The parent directory of each `SKILL.md` becomes the
   skill name.
2. **Store skills (build-time)** -- Flake input and path entries are merged
   into a single derivation in the nix store. Later store entries override
   earlier ones on name collision. Deployed via Home Manager file management.
3. **Git skills (activation-time)** -- Git source entries are cloned/updated as
   the user during Home Manager activation. Symlinked from the cache
   directory into each agent's skills path. Git skills override store skills
   on name collision.

## Configuration Reference

### `programs.ai-agents.enable`

- **Type:** `bool`
- **Default:** `false`
- **Description:** Whether to enable AI agent configuration management.

### `programs.ai-agents.agents`

- **Type:** `listOf (enum [ "opencode" "claude" "cursor" ])`
- **Default:** `[ "opencode" ]`
- **Description:** Which AI agents to configure. Controls skills deployment
  and, for supported agents, config file generation.

### `programs.ai-agents.skills`

- **Type:** `listOf (path | URL string | { source; ref?; rev?; include?; exclude?; })`
- **Default:** `[]`
- **Description:** List of skills sources. Path/flake entries are resolved at
  build time; git URL entries are cloned at activation time as the user.
  Git skills override store skills on name collision. Attrset entries may
  include `include` (whitelist) or `exclude` (blacklist) to filter which
  skills are deployed from that source.

### `programs.ai-agents.mcpServers`

- **Type:** `attrsOf (submodule { type; ... })`
- **Default:** `{}`
- **Description:** Shared MCP server definitions. Each server must have a
  `type` (defaults to `"stdio"`). All other fields are freeform. These are
  injected into every enabled agent's config. Per-agent MCP entries override
  shared definitions on name collision.

### `programs.ai-agents.opencode`

OpenCode-specific configuration.

#### `programs.ai-agents.opencode.config`

- **Type:** JSON attrset (freeform)
- **Default:** `{}`
- **Description:** Configuration serialized to `~/.config/opencode/opencode.json`.
  Shared `mcpServers` are automatically merged into the `mcp` key. Entries
  set here under `mcp` override shared definitions on name collision.

#### `programs.ai-agents.opencode.agentsFile`

- **Type:** `null` or `path`
- **Default:** `null`
- **Description:** Path to an AGENTS.md source file. Mutually exclusive with
  `agentsText`. Accepts `mkOutOfStoreSymlink` for live editing without rebuild.

#### `programs.ai-agents.opencode.agentsText`

- **Type:** `null` or `string`
- **Default:** `null`
- **Description:** Inline text content for AGENTS.md. Mutually exclusive with
  `agentsFile`.

## Updating

### Flake Inputs

```bash
nix flake update              # update all inputs
nix flake update skills-core  # update a single skills repo
```

### Git Source Entries

Git source entries are fetched on every activation. To pin a specific version,
set `rev` to a commit SHA. To clear the local cache and force a fresh clone:

```bash
rm -rf ~/.cache/nix-ai-agent-skills/repos/
```

## License

MIT
