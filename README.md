# nix-ai-agents

A Nix flake that manages AI coding agent configuration via Home Manager:
skills aggregation, config file generation, and shared MCP server definitions.

## Features

- **Skills aggregation** -- Merge skills from multiple repositories into a
  single directory, deployed to each enabled agent's config path.
- **Skill profiles** -- Group skills into named profiles deployed to separate
  directories, activated per-directory via direnv. An auto-generated `all`
  profile provides the full union for opencode; claude and cursor always
  receive the full union in their own skills directories.
- **Config generation** -- Generate agent config files (e.g., `opencode.json`)
  from Nix with per-host overrides through the module system.
- **Shared MCP servers** -- Define MCP servers once, automatically inject into
  all enabled agents. Per-agent overrides on name collision.
- **Subagents management** -- Deploy agent definition markdown files to each
  enabled agent's config path via live-editable symlinks.
- **AGENTS.md management** -- Deploy agent instruction files from a source
  path or inline text.

## Agent Support

| Agent | Skills Path | Agents Path | Config File | Status |
|---|---|---|---|---|
| `opencode` | `~/.config/opencode/skills/` | `~/.config/opencode/agents/` | `opencode.json` | Implemented |
| `claude` | `~/.claude/skills/` | `~/.claude/agents/` | -- | Skills + agents |
| `cursor` | `~/.cursor/skills/` | `~/.cursor/agents/` | -- | Skills + agents |

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

    skills = {
      core.source = inputs.skills-core;
    };

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

### Per-Host Skills Overrides

Since `skills` is `attrsOf skillSourceModule`, definitions across modules are
**deep-merged** by the Nix module system. A host can disable or filter a source
declared in shared config without replacing it:

```nix
# shared/home.nix
programs.ai-agents.skills = {
  core.source = inputs.skills-core;
};

# hosts/work-machine/home.nix -- disable a skill from the shared source
programs.ai-agents.skills.core.exclude = [ "personal-workflow" ];

# hosts/personal/home.nix -- disable the shared source entirely
programs.ai-agents.skills.core.enable = false;
```

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
programs.ai-agents.skills = {
  core.source = inputs.skills-core;
};
```

### Git Sources

Specify a git URL directly in the module config. Git source entries are
**cloned at Home Manager activation time** as the current user, so they
have access to SSH keys and git credential helpers. This makes them
suitable for private repositories that the nix daemon cannot access.

```nix
programs.ai-agents.skills = {
  # HTTPS URL
  my-skills = {
    source = "https://github.com/me/my-skills";
  };

  # With ref pinning
  my-skills-pinned = {
    source = "https://github.com/me/my-skills";
    ref = "v1.0.0";
  };

  # SSH URL
  corp-skills = {
    source = "git@github.com:corp/internal-skills.git";
    ref = "main";
  };
};
```

**Git source options:**

| Field | Required | Description |
|---|---|---|
| `source` | Yes | Git URL (HTTPS or SSH), path, or derivation |
| `enable` | No | Whether to deploy this source (default: `true`) |
| `ref` | No | Branch or tag name (git sources only) |
| `rev` | No | Exact commit SHA (git sources only) |
| `include` | No | List of skill names to deploy (whitelist). Mutually exclusive with `exclude`. |
| `exclude` | No | List of skill names to skip (blacklist). Mutually exclusive with `include`. |
| `priority` | No | Override order (default: `1000`). Lower loads first; higher wins on name collision. |

Cloned repos are cached in `~/.cache/nix-ai-agent-skills/repos/` and
updated on each activation.

### Precedence

Skills sources are sorted by `priority` (ascending). Lower priority loads first;
a higher-priority source wins on name collision. Git sources are deployed after
store sources, so at equal priority **git skills override store skills**.

To control override order explicitly, set `priority`:

```nix
programs.ai-agents.skills = {
  base = {
    source = inputs.skills-core;
    priority = 100;   # loads first, can be overridden
  };
  overrides = {
    source = inputs.skills-overrides;
    priority = 200;   # loads last, wins on name collision
  };
};
```

### Filtering Skills

Each skills entry can optionally specify an `include` list (whitelist) or
an `exclude` list (blacklist) to control which discovered skills get
deployed. These are mutually exclusive -- specifying both is an error.

Skill names correspond to the directory name containing the `SKILL.md` file.

```nix
programs.ai-agents.skills = {
  # Deploy only specific skills from a flake input
  core = {
    source = inputs.skills-core;
    include = [ "git-commit" "test-design" ];
  };

  # Deploy all skills except a few from a git source
  my-skills = {
    source = "https://github.com/me/my-skills";
    exclude = [ "deprecated-skill" "experimental" ];
  };

  # No filtering (deploy everything)
  other-skills.source = inputs.other-skills;
};
```

**Edge cases:**

- `include = []` -- empty whitelist matches nothing; no skills deployed
  from that source.
- `exclude = []` -- empty blacklist excludes nothing; all skills deployed.
- A nonexistent skill name in `include` or `exclude` is silently ignored.

## Skill Profiles

Skill profiles let you group skills into named sets deployed to separate
directories. opencode reads skills from a directory you configure per-project
(e.g., via direnv); claude and cursor always receive the full union in their
own skills directories.

### Declaring Profiles

```nix
programs.ai-agents.opencode.profiles = {
  gamedev = {
    dirs = [ "~/software/gamedev" "~/software/godot" ];
  };
  work = {
    dirs = [ "~/work" ];
  };
};
```

`dirs` lists the filesystem directories where this profile should activate.
The actual activation mechanism (e.g. direnv) is wired up separately using
`resolvedProfiles` -- see [Downstream Integration](#downstream-integration)
below.

**Constraints:**
- Profile names must match `[a-zA-Z0-9][a-zA-Z0-9._-]*`.
- `all` is reserved (auto-generated union -- see below).

### Assigning Skills to Profiles

Add a `profiles` attribute to any skills entry to restrict it to specific
profiles. Skills without `profiles` are backwards-compatible: they deploy to
the default `~/.config/opencode/skills/` directory as before.

```nix
programs.ai-agents.skills = {
  # No profiles attr -- always deployed to default opencode/skills/ (backwards compat)
  base-skills = {
    source = inputs.my-skills;
    include = [ "git-commit" "software-design" ];
  };

  # Deployed only to skill-profiles/gamedev/
  gamedev-skills = {
    source = inputs.my-skills;
    include = [ "godot" "love2d" "game-design" ];
    profiles = [ "gamedev" ];
  };

  # Same source, multiple profiles
  shared-skills = {
    source = inputs.my-skills;
    include = [ "python-design" "test-design" ];
    profiles = [ "work" "gamedev" ];
  };
};
```

Profile names in `profiles` must match a name declared in
`opencode.profiles`; referencing an undeclared profile is a module assertion
error.

**Edge case:** `profiles = []` (empty list) is distinct from `profiles = null`.
An empty list causes the skill to be excluded from the base `opencode/skills/`
directory and from all named profile directories. Behavior in `skill-profiles/all/`
differs by source type: store sources (flake inputs, paths) still appear in
`skill-profiles/all/` and in claude/cursor skills directories; git sources are
excluded from all opencode directories including `skill-profiles/all/`, but still
appear in claude/cursor skills directories. Use `profiles = null` (the default)
to deploy to the base opencode skills directory.

### The Auto-Generated `all` Profile

When any profiles are declared, `skill-profiles/all/` is always generated
containing the union of every skill (base + all profiles), priority-deduped.
This is an opencode-only path -- claude and cursor always receive the full
skill union deployed directly to their own skills directories
(`~/.claude/skills/`, `~/.cursor/skills/`), not from `skill-profiles/all/`.

### Downstream Integration

`config.programs.ai-agents.opencode.resolvedProfiles` exposes the computed
profile metadata as a read-only attribute for downstream consumers such as a
direnv integration in your dotfiles:

```nix
# Available to downstream consumers (e.g. direnv integration in dotfiles)
config.programs.ai-agents.opencode.resolvedProfiles
# => {
#   gamedev = { path = "/home/user/.config/opencode/skill-profiles/gamedev"; dirs = [ "~/software/gamedev" "~/software/godot" ]; };
#   work    = { path = "/home/user/.config/opencode/skill-profiles/work";    dirs = [ "~/work" ]; };
#   all     = { path = "/home/user/.config/opencode/skill-profiles/all";     dirs = []; };
# }
```

Each entry has:
- `path` -- absolute path to the profile's skills directory on disk.
- `dirs` -- filesystem directories that should activate this profile
  (empty for `all`).

### Backwards Compatibility

Skills without a `profiles` attribute behave identically to before: they are
deployed to `~/.config/opencode/skills/`. No changes are needed to existing
configs.

## How Skills Merging Works

1. **Discovery** -- Each skills source is scanned recursively for `SKILL.md`
   files at any depth. The parent directory of each `SKILL.md` becomes the
   skill name.
2. **Priority sort** -- Enabled sources are sorted by `priority` (ascending).
   Lower priority loads first; higher priority wins on name collision.
3. **Store skills (build-time)** -- Flake input and path entries are merged
   into a single derivation in the nix store. Deployed via Home Manager file
   management.
4. **Git skills (activation-time)** -- Git source entries are cloned/updated as
   the user during Home Manager activation. Symlinked from the cache
   directory into each agent's skills path. Git skills override store skills
   at equal priority because they are deployed after store skills.

## Subagents

Subagents are markdown files (e.g., `coder.md`, `security.md`) that define
specialized AI agents with custom prompts, models, tool permissions, and task
permissions. Unlike skills -- which are domain knowledge packs -- subagents
define agent behavior and capabilities.

Each `.md` file in the configured directories is symlinked into every enabled
agent tool's `agents/` directory. Symlinks point directly to the source files
(out-of-store) so they remain live-editable -- changes take effect immediately
without a rebuild.

### Usage

```nix
programs.ai-agents.subagents = [
  "${config.home.homeDirectory}/dotfiles/agents"
];
```

### Per-Host Subagents

Since `subagents` is `listOf str`, definitions across modules are
**concatenated** by the Nix module system. Per-host configs only need to add
extra directories -- later entries override earlier ones on filename collision.

```nix
# shared/home.nix
programs.ai-agents.subagents = [
  "${config.home.homeDirectory}/dotfiles/agents"
];

# hosts/work-machine/home.nix -- adds work-specific agents
programs.ai-agents.subagents = [
  "${config.home.homeDirectory}/dotfiles/work-agents"  # overrides shared on name collision
];
```

### Per-Machine Model Overrides

Per-machine model selection does not require different subagent files. Use
`opencode.config.agent` to override models via JSON config:

```nix
# hosts/work-machine/home.nix
programs.ai-agents.opencode.config.agent = {
  coder.model = "amazon-bedrock/anthropic.claude-sonnet-4";
  "pr-reviewer".model = "amazon-bedrock/anthropic.claude-sonnet-4";
  security.model = "amazon-bedrock/anthropic.claude-sonnet-4";
};

# hosts/personal/home.nix
programs.ai-agents.opencode.config.agent = {
  coder.model = "anthropic/claude-sonnet-4-20250514";
};
```

This works because OpenCode merges JSON config with markdown agent
definitions -- the JSON `agent.<name>.model` overrides the `model` field in
the markdown frontmatter. This keeps the verbose prompt content in shared,
live-editable markdown files while varying only the model per machine through
Nix.

### Cleanup

Managed symlinks are tracked in a manifest file. When a subagent source is
removed or a file is deleted, stale symlinks are automatically cleaned up on
the next `home-manager switch`.

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

- **Type:** `attrsOf (submodule { source; enable?; ref?; rev?; include?; exclude?; priority?; profiles?; })`
- **Default:** `{}`
- **Description:** Named skill sources. Each key is a logical name for the
  source. The `attrsOf` type enables per-host deep merging through the Nix
  module system -- a host can disable or filter a source declared in shared
  config without replacing it entirely. Sources are sorted by `priority`
  (ascending, default `1000`); lower loads first, higher wins on name
  collision. Path/package entries are resolved at build time; git URL string
  entries are cloned at activation time as the user. Git skills override store
  skills at equal priority. The optional `profiles` list restricts deployment
  to the named skill profiles; `null` (default) deploys to the default skills
  directory for backwards compatibility.

### `programs.ai-agents.subagents`

- **Type:** `listOf str`
- **Default:** `[]`
- **Description:** List of absolute paths to directories containing agent
  definition markdown files (`.md`). Each `.md` file is symlinked into every
  configured agent tool's `agents/` directory. Symlinks point directly to the
  source files (out-of-store) so they remain live-editable. Later entries
  override earlier ones on filename collision. Managed symlinks are tracked
  via a manifest for automatic cleanup.

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

#### `programs.ai-agents.opencode.profiles`

- **Type:** `attrsOf (submodule { dirs; })`
- **Default:** `{}`
- **Description:** Named skill profiles. Each key is a profile name (must
  match `[a-zA-Z0-9][a-zA-Z0-9._-]*`; `all` is reserved). Each profile is
  deployed to `~/.config/opencode/skill-profiles/<name>/`. The `dirs` list
  records which filesystem directories should activate this profile -- used by
  downstream consumers such as a direnv integration. When any profiles are
  declared, `skill-profiles/all/` is always generated as the union of all
  skills. Profiles are opencode-specific; if `opencode` is not in `agents`,
  profile directories are not deployed and `resolvedProfiles` paths will not
  exist on disk.

#### `programs.ai-agents.opencode.resolvedProfiles`

- **Type:** read-only `attrsOf (submodule { path; dirs; })`
- **Default:** `{ all = { path = "~/.config/opencode/skill-profiles/all"; dirs = []; }; }`
- **Description:** Computed profile metadata exposed for downstream consumers.
  Populated automatically from `opencode.profiles`; do not set directly. Each
  entry contains the absolute `path` to the profile's skills directory and the
  `dirs` list from the profile declaration. Always includes an `all` entry
  (pointing to `skill-profiles/all/`) even when no profiles are declared;
  however, `skill-profiles/all/` is only deployed to disk when at least one
  profile is declared. Downstream consumers should check
  `cfg.opencode.profiles == {}` to detect the no-profiles case rather than
  testing `resolvedProfiles == {}`.

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
