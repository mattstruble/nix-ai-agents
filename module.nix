{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.ai-agents;
  jsonFormat = pkgs.formats.json { };

  # Agents under XDG config use xdg.configFile; others use home.file
  xdgAgents = [ "opencode" ];

  agentSkillsPath = {
    opencode = "opencode/skills";
    claude = ".claude/skills";
    cursor = ".cursor/skills";
    pi = ".pi/agent/skills";
  };

  agentSubagentsPath = {
    opencode = "opencode/agents";
    claude = ".claude/agents";
    cursor = ".cursor/agents";
    pi = ".pi/agent/agents";
  };

  skillSourceModule = lib.types.submodule {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to enable this skill source.";
      };
      source = lib.mkOption {
        type =
          with lib.types;
          oneOf [
            path
            package
            str
          ];
        description = "Path, derivation (flake input), or git URL string.";
      };
      ref = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Git branch or tag (git sources only).";
      };
      rev = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Git commit SHA (git sources only).";
      };
      include = lib.mkOption {
        type = with lib.types; nullOr (listOf str);
        default = null;
        description = "Whitelist: deploy only these skill names from this source.";
      };
      exclude = lib.mkOption {
        type = with lib.types; nullOr (listOf str);
        default = null;
        description = "Blacklist: deploy all skills except these from this source.";
      };
      priority = lib.mkOption {
        type = lib.types.int;
        default = 1000;
        description = "Override order. Lower loads first; higher overrides on name collision.";
      };
      profiles = lib.mkOption {
        type = with lib.types; nullOr (listOf str);
        default = null;
        description = "Profile names this skill belongs to. null = base (always deployed to default skills directory, backwards-compatible behavior).";
      };
    };
  };

  # Detect whether a string value is a git remote URL.
  isGitSource =
    s:
    builtins.isString s
    && (
      lib.hasPrefix "https://" s
      || (
        lib.hasPrefix "http://" s
        && lib.warn "programs.ai-agents: HTTP git source '${s}' is insecure; prefer HTTPS." true
      )
      || lib.hasPrefix "git@" s
      || lib.hasPrefix "ssh://" s
      || (
        lib.hasPrefix "git://" s
        && lib.warn "programs.ai-agents: git:// protocol is unencrypted; prefer SSH or HTTPS." true
      )
      || lib.hasPrefix "git+ssh://" s
      || lib.hasPrefix "git+https://" s
    );

  # Detect whether a git URL requires SSH authentication.
  isSSHSource = s: lib.hasPrefix "git@" s || lib.hasPrefix "ssh://" s || lib.hasPrefix "git+ssh://" s;

  # Validate that a skill name contains only safe characters for shell interpolation.
  # Matches: letters, digits, dots, underscores, hyphens.
  isValidSkillName = name: builtins.match "[a-zA-Z0-9._-]+" name != null;

  # Sort enabled skills by priority, partition by source type
  enabledSkills = lib.pipe cfg.skills [
    (lib.filterAttrs (_: v: v.enable))
    lib.attrsToList
    (builtins.sort (a: b: a.value.priority < b.value.priority))
    (map (x: x.value))
  ];

  isStoreSource = entry: !(builtins.isString entry.source && isGitSource entry.source);
  storeSkills = builtins.filter isStoreSource enabledSkills;
  gitSkillEntries = builtins.filter (e: !isStoreSource e) enabledSkills;

  # Partition store skills by profile membership
  baseStoreSkills = builtins.filter (s: s.profiles == null) storeSkills;
  profiledStoreSkills = builtins.filter (s: s.profiles != null) storeSkills;

  # Whether any git skill source uses an SSH URL.
  hasSSHSkills = builtins.any (e: builtins.isString e.source && isSSHSource e.source) gitSkillEntries;

  mcpServerType = lib.types.submodule {
    freeformType = jsonFormat.type;
    options = {
      type = lib.mkOption {
        type = lib.types.str;
        default = "stdio";
        description = "MCP server type (stdio, remote, sse).";
      };
    };
  };

  # Generate a bash case snippet that filters by skill name.
  # - include non-null + non-empty: only matching names pass through
  # - include = []: skip all (empty whitelist matches nothing)
  # - exclude non-null + non-empty: matching names are skipped
  # - exclude = []: no filter (empty blacklist excludes nothing)
  # - both null: no filter (empty string)
  mkSkillFilter =
    { include, exclude }:
    if include != null then
      if include == [ ] then
        "continue"
      else
        let
          patterns = lib.concatMapStringsSep "|" (n: ''"${n}"'') include;
        in
        ''
          case "$name" in
            ${patterns}) ;;
            *) continue ;;
          esac
        ''
    else if exclude != null then
      if exclude == [ ] then
        ""
      else
        let
          patterns = lib.concatMapStringsSep "|" (n: ''"${n}"'') exclude;
        in
        ''
          case "$name" in
            ${patterns}) continue ;;
            *) ;;
          esac
        ''
    else
      "";

  # Helper: build a merged-skills derivation from a list of skill entries
  mkMergedSkills =
    name: skills:
    pkgs.runCommandLocal name { } ''
      mkdir -p $out
      ${lib.concatMapStringsSep "\n" (
        skill:
        let
          filterSnippet = mkSkillFilter { inherit (skill) include exclude; };
        in
        ''
          find "${skill.source}" -name "SKILL.md" -type f | while read -r skillfile; do
            skill_dir="$(dirname "$skillfile")"
            name="$(basename "$skill_dir")"
            ${filterSnippet}
            rm -rf "$out/$name"
            cp -rL "$skill_dir" "$out/$name"
          done
        ''
      ) skills}
    '';

  # Base skills (profiles = null) → deployed to default skills directory
  mergedBaseSkills = mkMergedSkills "merged-ai-agent-base-skills" baseStoreSkills;

  # Per-profile derivations — one per declared profile, containing only skills targeting it
  mergedProfileSkills = lib.mapAttrs (
    profileName: _:
    let
      skillsForProfile = builtins.filter (s: builtins.elem profileName s.profiles) profiledStoreSkills;
    in
    mkMergedSkills "merged-ai-agent-profile-${profileName}-skills" skillsForProfile
  ) cfg.opencode.profiles;

  # All skills union (base + all profiles), priority-deduped — for Claude/Cursor
  mergedAllSkills = mkMergedSkills "merged-ai-agent-all-skills" storeSkills;

  # Build final opencode config with shared MCPs merged in.
  # Agent-specific MCPs (from opencode.config.mcp) override shared on name collision.
  finalOpencodeConfig =
    let
      sharedMcps = cfg.mcpServers;
      agentMcps = cfg.opencode.config.mcp or { };
      mergedMcps = sharedMcps // agentMcps;
      baseConfig = builtins.removeAttrs cfg.opencode.config [ "mcp" ];
    in
    if mergedMcps == { } then cfg.opencode.config else baseConfig // { mcp = mergedMcps; };

  isXdgAgent = agent: builtins.elem agent xdgAgents;

  agentSkillsAbsPath =
    agent:
    if isXdgAgent agent then
      "${config.xdg.configHome}/${agentSkillsPath.${agent}}"
    else
      "${config.home.homeDirectory}/${agentSkillsPath.${agent}}";

  agentSubagentsAbsPath =
    agent:
    if isXdgAgent agent then
      "${config.xdg.configHome}/${agentSubagentsPath.${agent}}"
    else
      "${config.home.homeDirectory}/${agentSubagentsPath.${agent}}";

  cacheDir = "${config.xdg.cacheHome}/nix-ai-agent-skills";

  subagentsManifestFile = "${cacheDir}/managed-subagents.list";

  subagentsScript =
    let
      agentDirs = map agentSubagentsAbsPath cfg.agents;
      agentDirsStr = lib.concatMapStringsSep " " (d: ''"${d}"'') agentDirs;
    in
    ''
      _SUBAGENT_DIRS=(${agentDirsStr})

      # Ensure target directories exist
      for _dir in "''${_SUBAGENT_DIRS[@]}"; do
        mkdir -p "$_dir"
      done

      # Ensure cache directory exists
      mkdir -p ${lib.escapeShellArg cacheDir}

      # Clean old managed symlinks from manifest (NUL-delimited)
      if [ -f ${lib.escapeShellArg subagentsManifestFile} ]; then
        while IFS= read -r -d "" _link; do
          [ -L "$_link" ] && rm -f "$_link"
        done < ${lib.escapeShellArg subagentsManifestFile}
      fi

      # Clear manifest for fresh write
      : > ${lib.escapeShellArg subagentsManifestFile}

      # Deploy subagent symlinks
      ${lib.concatMapStringsSep "\n" (srcDir: ''
        if [ -d ${lib.escapeShellArg srcDir} ]; then
          for _md in ${lib.escapeShellArg srcDir}/*.md; do
            [ -f "$_md" ] || continue
            _filename="$(basename "$_md")"
            for _dir in "''${_SUBAGENT_DIRS[@]}"; do
              ln -snf "$_md" "$_dir/$_filename"
              printf '%s\0' "$_dir/$_filename" >> ${lib.escapeShellArg subagentsManifestFile}
            done
          done
        else
          echo "Warning: subagents directory ${lib.escapeShellArg srcDir} does not exist; skipping." >&2
        fi
      '') cfg.subagents}
    '';

  gitSkillsScript =
    let
      agentDirs = map agentSkillsAbsPath cfg.agents;
      agentDirsStr = lib.concatMapStringsSep " " (d: ''"${d}"'') agentDirs;

      # Profile dirs under opencode/skill-profiles/<name>/ and .../all/
      opencodeProfilesBase = "${config.xdg.configHome}/opencode/skill-profiles";

      # Space-separated list of declared profile names for use in a bash for-loop (build-time)
      profileNamesStr = lib.concatMapStringsSep " " (n: ''"${n}"'') (
        builtins.attrNames cfg.opencode.profiles
      );

      # Export SSH_AUTH_SOCK if configured. The value is stored in a
      # shell variable via escapeShellArg to prevent injection, then
      # used in ${:-} to not clobber any value already in the environment.
      sshSetup = lib.optionalString (cfg.sshAuthSock != null) ''
        _nix_ssh_sock=${lib.escapeShellArg cfg.sshAuthSock}
        export SSH_AUTH_SOCK="''${SSH_AUTH_SOCK:-$_nix_ssh_sock}"
      '';

      # Runtime pre-flight warning when SSH sources exist but socket is unset.
      sshPreFlight = lib.optionalString hasSSHSkills ''
        if [ -z "''${SSH_AUTH_SOCK:-}" ]; then
          echo "Warning: SSH_AUTH_SOCK is not set; SSH git skill sources will likely fail." >&2
          echo "  Set home.sessionVariables.SSH_AUTH_SOCK or programs.ai-agents.sshAuthSock." >&2
        fi
      '';

      # Trust model: activation-time git clones are NOT integrity-verified
      # like flake inputs (which use content hashes in flake.lock). A
      # compromised remote or MITM on insecure transports (http://, git://)
      # can deliver arbitrary content into agent skill directories. Pin with
      # `rev` for reproducibility; prefer flake inputs for strong integrity.
      cloneSnippets = lib.concatMapStrings (
        entry:
        let
          urlHash = builtins.hashString "sha256" "${entry.source}#${entry.ref}#${entry.rev}";
          escapedSource = lib.escapeShellArg entry.source;
        in
        ''
          _repo="${cacheDir}/repos/${urlHash}"
          if [ -d "$_repo/.git" ]; then
            ${pkgs.git}/bin/git -C "$_repo" fetch --quiet ${
              lib.optionalString (entry.rev == "") "--depth 1"
            } || \
              echo 'Warning: failed to fetch' ${escapedSource} >&2
            ${
              if entry.rev != "" then
                ''
                  ${pkgs.git}/bin/git -C "$_repo" checkout --quiet ${lib.escapeShellArg entry.rev}
                ''
              else if entry.ref != "" then
                ''
                  # Ensure correct branch/tag is checked out (fixes detached HEAD from prior rev pin)
                  if ${pkgs.git}/bin/git -C "$_repo" show-ref --verify --quiet "refs/tags/"${lib.escapeShellArg entry.ref} 2>/dev/null; then
                    # ref is a tag -- checkout only, no pull (tags don't track upstream)
                    ${pkgs.git}/bin/git -C "$_repo" checkout --quiet ${lib.escapeShellArg entry.ref}
                  else
                    # ref is a branch -- checkout and pull
                    ${pkgs.git}/bin/git -C "$_repo" checkout --quiet ${lib.escapeShellArg entry.ref} 2>/dev/null || true
                    ${pkgs.git}/bin/git -C "$_repo" pull --quiet || \
                      echo 'Warning: failed to update' ${escapedSource} >&2
                  fi
                ''
              else
                ''
                  # Detect and checkout default branch (fixes detached HEAD from prior rev pin)
                  _default_branch="$(${pkgs.git}/bin/git -C "$_repo" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')" || true
                  ${pkgs.git}/bin/git -C "$_repo" checkout --quiet "''${_default_branch:-main}" 2>/dev/null || true
                  ${pkgs.git}/bin/git -C "$_repo" pull --quiet || \
                    echo 'Warning: failed to update' ${escapedSource} >&2
                ''
            }
          else
            ${pkgs.git}/bin/git clone --quiet \
              ${lib.optionalString (entry.rev == "") "--depth 1"} \
              ${
                lib.optionalString (
                  entry.rev == "" && entry.ref != ""
                ) "--single-branch --branch ${lib.escapeShellArg entry.ref}"
              } \
              ${
                lib.optionalString (entry.rev != "" && entry.ref != "") "--branch ${lib.escapeShellArg entry.ref}"
              } \
              ${escapedSource} "$_repo" || \
              echo 'Warning: failed to clone' ${escapedSource} '(is SSH_AUTH_SOCK set?)' >&2
            ${lib.optionalString (entry.rev != "") ''
              ${pkgs.git}/bin/git -C "$_repo" checkout --quiet ${lib.escapeShellArg entry.rev}
            ''}
          fi
        ''
      ) gitSkillEntries;

      # Deploy snippet for a single git entry.
      # Base entries (profiles=null): symlink into opencode base dir + claude/cursor dirs.
      # Profiled entries: symlink into each targeted skill-profiles/<name>/ + claude/cursor dirs.
      # All entries also land in skill-profiles/all/ (opencode only).
      hasOpencode = builtins.elem "opencode" cfg.agents;

      mkDeploySnippet =
        entry:
        let
          urlHash = builtins.hashString "sha256" "${entry.source}#${entry.ref}#${entry.rev}";
          filterSnippet = mkSkillFilter { inherit (entry) include exclude; };
          # Non-opencode agent dirs (claude, cursor) — always get all git skills
          nonOpencodeAgentDirs = builtins.filter (d: d != agentSkillsAbsPath "opencode") agentDirs;
          nonOpencodeStr = lib.concatMapStringsSep " " (d: ''"${d}"'') nonOpencodeAgentDirs;
          # Per-profile target dirs for opencode (build-time known from entry.profiles)
          opencodeTargets =
            if !hasOpencode then
              [ ]
            else if entry.profiles == null then
              # base: opencode base skills dir
              [ (agentSkillsAbsPath "opencode") ]
            else
              # profiled: one dir per targeted profile
              map (p: "${opencodeProfilesBase}/${p}") entry.profiles;
          opencodeTargetsStr = lib.concatMapStringsSep " " (d: ''"${d}"'') opencodeTargets;
        in
        ''
          if [ -d "${cacheDir}/repos/${urlHash}" ]; then
            find "${cacheDir}/repos/${urlHash}" -name "SKILL.md" -type f | while read -r skillfile; do
              skill_dir="$(dirname "$skillfile")"
              name="$(basename "$skill_dir")"
              ${filterSnippet}
              ${lib.optionalString (opencodeTargets != [ ]) ''
                # Deploy to opencode target dirs (base or per-profile)
                for _dir in ${opencodeTargetsStr}; do
                  mkdir -p "$_dir"
                  ln -snf "$skill_dir" "$_dir/$name"
                done
                ${lib.optionalString (cfg.opencode.profiles != { }) ''
                  # Deploy to skill-profiles/all/ (opencode)
                  mkdir -p "${opencodeProfilesBase}/all"
                  ln -snf "$skill_dir" "${opencodeProfilesBase}/all/$name"
                ''}
              ''}
              # Deploy to non-opencode agent dirs (claude, cursor) — always all skills
              ${lib.optionalString (nonOpencodeAgentDirs != [ ]) ''
                for _dir in ${nonOpencodeStr}; do
                  ln -snf "$skill_dir" "$_dir/$name"
                done
              ''}
            done
          fi
        '';

      deploySnippets = lib.concatMapStrings mkDeploySnippet gitSkillEntries;
    in
    ''
      ${sshSetup}
      ${sshPreFlight}
      _AGENT_DIRS=(${agentDirsStr})
      mkdir -p "${cacheDir}/repos"

      # Ensure agent skill directories exist
      for _dir in "''${_AGENT_DIRS[@]}"; do
        mkdir -p "$_dir"
      done

      # Clean old git-managed symlinks (those pointing to cache dir)
      # Covers: agent base dirs, skill-profiles/<name>/, skill-profiles/all/
      for _dir in "''${_AGENT_DIRS[@]}"; do
        [ -d "$_dir" ] || continue
        for _entry in "$_dir"/*; do
          [ -L "$_entry" ] || continue
          case "$(readlink "$_entry")" in
            "${cacheDir}"/*) rm -f "$_entry" ;;
          esac
        done
      done
      ${lib.optionalString hasOpencode ''
        # Clean stale git symlinks from skill-profiles/<name>/ and skill-profiles/all/
        for _profile_name in ${profileNamesStr} all; do
          _dir="${opencodeProfilesBase}/$_profile_name"
          [ -d "$_dir" ] || continue
          for _entry in "$_dir"/*; do
            [ -L "$_entry" ] || continue
            case "$(readlink "$_entry")" in
              "${cacheDir}"/*) rm -f "$_entry" ;;
            esac
          done
        done
      ''}

      # Clone/update repos
      ${cloneSnippets}

      # Deploy git skills (overrides store skills on name collision)
      ${deploySnippets}
    '';

in
{
  options.programs.ai-agents = {
    enable = lib.mkEnableOption "AI agent configuration management";

    agents = lib.mkOption {
      type = lib.types.listOf (
        lib.types.enum [
          "opencode"
          "claude"
          "cursor"
          "pi"
        ]
      );
      default = [ "opencode" ];
      description = "Which AI agents to configure.";
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf skillSourceModule;
      default = { };
      description = ''
        Named skill sources. Each key is a logical name for the source.
        Values are attrsets with source, filtering, and priority options.

        The attrsOf type enables per-host deep merging -- a host can add
        exclude entries or disable a source declared in shared config:

          programs.ai-agents.skills.mattstruble.exclude = [ "unwanted-skill" ];
          programs.ai-agents.skills.mattstruble.enable = false;

        Sources are sorted by priority (ascending). Lower priority loads
        first; higher priority overrides on name collision. Git sources
        override store sources when priorities are equal.

        Skills are discovered recursively: any SKILL.md file at any depth
        within a source has its parent directory name used as the skill name.
      '';
    };

    sshAuthSock = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      # `or null` is Nix attribute-access-with-fallback syntax:
      # returns the value if the key exists in the attrset, null otherwise.
      default = config.home.sessionVariables.SSH_AUTH_SOCK or null;
      defaultText = lib.literalExpression "config.home.sessionVariables.SSH_AUTH_SOCK or null";
      description = ''
        Path to the SSH agent socket, forwarded into the activation
        environment for git skill sources that use SSH (`git@`, `ssh://`).

        Defaults to `home.sessionVariables.SSH_AUTH_SOCK` when set.
        Override explicitly if your SSH agent socket is managed outside
        Home Manager (e.g. 1Password via launchd, gpg-agent).

        Set to `null` to disable (HTTPS-only git sources don't need this).
      '';
    };

    subagents = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        List of absolute paths to directories containing agent definition
        markdown files (.md). Each .md file found in these directories is
        symlinked (by its full filename) into every configured agent tool's
        agents/ directory.

        Paths are symlinked directly (out-of-store) so files remain
        live-editable. Later entries override earlier ones on name collision.

        Example:
          subagents = [
            "/home/user/dotfiles/agents"       # shared base agents
            "/home/user/dotfiles/work-agents"  # machine-specific override
          ];
      '';
    };

    mcpServers = lib.mkOption {
      type = lib.types.attrsOf mcpServerType;
      default = { };
      description = ''
        Shared MCP server definitions applied to all enabled agents.
        Per-agent config overrides shared definitions on name collision.
      '';
    };

    opencode = lib.mkOption {
      type = lib.types.submodule {
        options = {
          config = lib.mkOption {
            type = jsonFormat.type;
            default = { };
            description = ''
              Configuration attrset serialized to opencode.json.
              Shared mcpServers are automatically injected into the mcp key.
              Agent-specific mcp entries here override shared definitions
              on name collision.
            '';
          };

          agentsFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to AGENTS.md source file.";
          };

          agentsText = lib.mkOption {
            type = lib.types.nullOr lib.types.lines;
            default = null;
            description = "Inline text content for AGENTS.md.";
          };

          profiles = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule {
                options.dirs = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  description = "Directories where this profile activates via direnv.";
                };
              }
            );
            default = { };
            description = "Named skill profiles. Each profile groups skills deployed to a separate directory and optionally maps to filesystem directories for direnv activation.";
          };

          resolvedProfiles = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule {
                options = {
                  path = lib.mkOption {
                    type = lib.types.str;
                    internal = true;
                    description = "Absolute runtime path where this profile's skills directory is deployed.";
                  };
                  dirs = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    internal = true;
                    description = "Filesystem directories that should activate this profile.";
                  };
                };
              }
            );
            internal = true;
            default = { };
            description = "Resolved profile metadata for downstream consumers (e.g. direnv integration).";
          };
        };
      };
      default = { };
      description = "OpenCode agent configuration.";
    };

    pi = lib.mkOption {
      type = lib.types.submodule {
        options = {
          config = lib.mkOption {
            type = jsonFormat.type;
            default = { };
            description = ''
              Configuration attrset serialized to ~/.pi/agent/settings.json.
              The packages list is merged in from pi.packages.
            '';
          };

          systemPromptFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to SYSTEM.md source file, deployed to ~/.pi/agent/SYSTEM.md.";
          };

          agentsFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to AGENTS.md source file, deployed to ~/.pi/agent/AGENTS.md.";
          };

          extensions = lib.mkOption {
            type = lib.types.attrsOf lib.types.path;
            default = { };
            description = ''
              Attrset of extension files. Keys are filenames (e.g. "skill-enforcer.ts"),
              values are source paths. Each is symlinked into ~/.pi/agent/extensions/<key>.
            '';
          };

          packages = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = ''
              npm package specs merged into the packages array in settings.json
              and installed via `pi install` during activation.
            '';
          };

          auth = lib.mkOption {
            type = jsonFormat.type;
            default = { };
            description = "Content of ~/.pi/agent/auth.json (provider authentication).";
          };

          permissionConfig = lib.mkOption {
            type = jsonFormat.type;
            default = { };
            description = "Content of ~/.pi/agent/extensions/pi-permission-system/config.json.";
          };
        };
      };
      default = { };
      description = "Pi agent configuration.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # Assertions
      {
        assertions = [
          {
            assertion = !(cfg.opencode.agentsFile != null && cfg.opencode.agentsText != null);
            message = "programs.ai-agents.opencode.agentsFile and agentsText are mutually exclusive.";
          }
        ]
        # include and exclude are mutually exclusive per skill entry
        ++ (lib.mapAttrsToList (name: entry: {
          assertion = !(entry.include != null && entry.exclude != null);
          message = "programs.ai-agents.skills.${name}: 'include' and 'exclude' are mutually exclusive.";
        }) cfg.skills)
        # string sources must be valid git URLs, not arbitrary strings
        ++ (lib.mapAttrsToList (name: entry: {
          assertion = !(builtins.isString entry.source && !isGitSource entry.source);
          message =
            # entry.source is always a string when this assertion fires
            "programs.ai-agents.skills.${name}: string source '${
              if builtins.isString entry.source then entry.source else "<non-string>"
            }' is not a recognised git URL. Use a path literal, package, or a URL beginning with https://, git@, ssh://, etc.";
        }) cfg.skills)
        # ref and rev are only meaningful for git sources
        ++ (lib.mapAttrsToList (name: entry: {
          assertion =
            !(
              (entry.ref != "" || entry.rev != "")
              && !(builtins.isString entry.source && isGitSource entry.source)
            );
          message = "programs.ai-agents.skills.${name}: 'ref' and 'rev' are only valid for git sources.";
        }) cfg.skills)
        # include/exclude entries must be valid skill names (alphanumeric, dots, underscores, hyphens)
        ++ (lib.concatLists (
          lib.mapAttrsToList (
            name: entry:
            let
              includeNames = if entry.include != null then entry.include else [ ];
              excludeNames = if entry.exclude != null then entry.exclude else [ ];
            in
            (lib.imap0 (j: n: {
              assertion = isValidSkillName n;
              message = "programs.ai-agents.skills.${name}.include[${toString j}]: '${n}' contains invalid characters.";
            }) includeNames)
            ++ (lib.imap0 (j: n: {
              assertion = isValidSkillName n;
              message = "programs.ai-agents.skills.${name}.exclude[${toString j}]: '${n}' contains invalid characters.";
            }) excludeNames)
          ) cfg.skills
        ))
        # subagent entries must be absolute paths without newlines
        ++ (lib.imap0 (i: dir: {
          assertion = lib.hasPrefix "/" dir && builtins.match "[^\n\r]+" dir != null;
          message = "programs.ai-agents.subagents[${toString i}]: must be an absolute path without newlines.";
        }) cfg.subagents)
        # skill profiles must reference declared opencode.profiles names
        ++ [
          {
            assertion = lib.all (
              entry:
              entry.profiles == null || lib.all (p: builtins.hasAttr p cfg.opencode.profiles) entry.profiles
            ) (lib.attrValues cfg.skills);
            message =
              let
                badEntries = lib.filter (
                  entry:
                  entry.profiles != null && lib.any (p: !builtins.hasAttr p cfg.opencode.profiles) entry.profiles
                ) (lib.attrValues cfg.skills);
                badProfiles = lib.concatMap (
                  entry: lib.filter (p: !builtins.hasAttr p cfg.opencode.profiles) entry.profiles
                ) badEntries;
                available = lib.concatStringsSep ", " (builtins.attrNames cfg.opencode.profiles);
              in
              "programs.ai-agents: unknown profile(s): ${lib.concatStringsSep ", " (lib.unique badProfiles)}. Available profiles: ${available}";
          }
        ]
        # profile names must be safe for use as filesystem path components and derivation names
        # Require alphanumeric start to exclude ".", "..", and leading-dot/hyphen names
        ++ (lib.mapAttrsToList (profileName: _: {
          assertion = builtins.match "[a-zA-Z0-9][a-zA-Z0-9._-]*" profileName != null;
          message = "programs.ai-agents.opencode.profiles: profile name '${profileName}' is invalid. Must start with a letter or digit and contain only letters, digits, dots, underscores, and hyphens.";
        }) cfg.opencode.profiles)
        # "all" is reserved for the union skill-profiles/all/ directory
        ++ (lib.mapAttrsToList (profileName: _: {
          assertion = profileName != "all";
          message = "programs.ai-agents.opencode.profiles: 'all' is a reserved profile name.";
        }) cfg.opencode.profiles);
      }

      # Store skills deployment (build-time, via Home Manager file management)
      (lib.mkIf (storeSkills != [ ]) {
        # XDG-managed agents (opencode)
        xdg.configFile =
          lib.optionalAttrs (baseStoreSkills != [ ]) (
            lib.listToAttrs (
              map (
                agent:
                lib.nameValuePair agentSkillsPath.${agent} {
                  source = mergedBaseSkills;
                  recursive = true;
                }
              ) (builtins.filter isXdgAgent cfg.agents)
            )
          )
          # Per-profile directories (only when profiles are declared and opencode is configured)
          // lib.optionalAttrs (cfg.opencode.profiles != { } && builtins.elem "opencode" cfg.agents) (
            lib.mapAttrs' (
              profileName: drv:
              lib.nameValuePair "opencode/skill-profiles/${profileName}" {
                source = drv;
                recursive = true;
              }
            ) mergedProfileSkills
            // {
              "opencode/skill-profiles/all" = {
                source = mergedAllSkills;
                recursive = true;
              };
            }
          );

        # Home-managed agents (claude, cursor) — receive all skills (base + profiled)
        home.file = lib.listToAttrs (
          map (
            agent:
            lib.nameValuePair agentSkillsPath.${agent} {
              source = mergedAllSkills;
              recursive = true;
            }
          ) (builtins.filter (a: !isXdgAgent a) cfg.agents)
        );
      })

      # Git skills deployment (activation-time, as user)
      (lib.mkIf (gitSkillEntries != [ ]) {
        home.activation.deployGitSkills = lib.hm.dag.entryAfter [ "linkGeneration" ] gitSkillsScript;
      })

      # Subagents deployment (activation-time, out-of-store symlinks)
      # Runs unconditionally so that stale symlinks are cleaned up when
      # the subagents list transitions from non-empty to empty.
      {
        home.activation.deploySubagents = lib.hm.dag.entryAfter [ "linkGeneration" ] subagentsScript;
      }

      # OpenCode: generate opencode.json
      (lib.mkIf (builtins.elem "opencode" cfg.agents && finalOpencodeConfig != { }) {
        xdg.configFile."opencode/opencode.json".source =
          jsonFormat.generate "opencode.json" finalOpencodeConfig;
      })

      # OpenCode: AGENTS.md from file
      (lib.mkIf (cfg.opencode.agentsFile != null) {
        xdg.configFile."opencode/AGENTS.md".source = cfg.opencode.agentsFile;
      })

      # OpenCode: AGENTS.md from inline text
      (lib.mkIf (cfg.opencode.agentsText != null) {
        xdg.configFile."opencode/AGENTS.md".text = cfg.opencode.agentsText;
      })

      # Expose resolved profile metadata for downstream consumers (e.g. direnv integration)
      {
        programs.ai-agents.opencode.resolvedProfiles =
          (lib.mapAttrs (name: profile: {
            path = "${config.xdg.configHome}/opencode/skill-profiles/${name}";
            dirs = profile.dirs;
          }) cfg.opencode.profiles)
          // {
            all = {
              path = "${config.xdg.configHome}/opencode/skill-profiles/all";
              dirs = [ ];
            };
          };
      }

      # Pi: generate settings.json (merges packages into config)
      (lib.mkIf (builtins.elem "pi" cfg.agents) (
        let
          finalPiConfig =
            if cfg.pi.packages == [ ] then
              cfg.pi.config
            else
              cfg.pi.config
              // {
                packages = (cfg.pi.config.packages or [ ]) ++ cfg.pi.packages;
              };
        in
        lib.mkIf (finalPiConfig != { }) {
          home.file.".pi/agent/settings.json".source = jsonFormat.generate "pi-settings.json" finalPiConfig;
        }
      ))

      # Pi: SYSTEM.md
      (lib.mkIf (builtins.elem "pi" cfg.agents && cfg.pi.systemPromptFile != null) {
        home.file.".pi/agent/SYSTEM.md".source = cfg.pi.systemPromptFile;
      })

      # Pi: AGENTS.md
      (lib.mkIf (builtins.elem "pi" cfg.agents && cfg.pi.agentsFile != null) {
        home.file.".pi/agent/AGENTS.md".source = cfg.pi.agentsFile;
      })

      # Pi: extensions — symlink each .ts file by key name
      (lib.mkIf (builtins.elem "pi" cfg.agents && cfg.pi.extensions != { }) {
        home.file = lib.mapAttrs' (
          name: source:
          lib.nameValuePair ".pi/agent/extensions/${name}" {
            inherit source;
          }
        ) cfg.pi.extensions;
      })

      # Pi: install declared packages via activation script
      (lib.mkIf (builtins.elem "pi" cfg.agents && cfg.pi.packages != [ ]) {
        home.activation.piInstallPackages = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
          if command -v pi &>/dev/null; then
            ${lib.concatMapStringsSep "\n" (pkg: ''
              pi install ${lib.escapeShellArg pkg}
            '') cfg.pi.packages}
            # Approve pending install scripts (e.g., tree-sitter native builds)
            if [ -d "$HOME/.pi/agent" ]; then
              (cd "$HOME/.pi/agent" && npm approve-scripts --allow-scripts-pending 2>/dev/null || true)
            fi
          else
            echo "Warning: 'pi' not found in PATH; skipping package installation." >&2
          fi
        '';
      })

      # Pi: auth.json
      (lib.mkIf (builtins.elem "pi" cfg.agents && cfg.pi.auth != { }) {
        home.file.".pi/agent/auth.json".source = jsonFormat.generate "pi-auth.json" cfg.pi.auth;
      })

      # Pi: pi-permission-system config
      (lib.mkIf (builtins.elem "pi" cfg.agents && cfg.pi.permissionConfig != { }) {
        home.file.".pi/agent/extensions/pi-permission-system/config.json".source =
          jsonFormat.generate "pi-permission-system-config.json" cfg.pi.permissionConfig;
      })

    ]
  );
}
