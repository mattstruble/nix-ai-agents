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
  };

  skillType = lib.mkOptionType {
    name = "skillSource";
    description = "path, URL string, or { source, ref?, rev?, include?, exclude? }";
    check =
      x:
      builtins.isPath x
      || builtins.isString x
      || (
        builtins.isAttrs x
        && (x ? source || x ? outPath)
        && (!(x ? include) || builtins.isList x.include)
        && (!(x ? exclude) || builtins.isList x.exclude)
        && (!(x ? ref) || builtins.isString x.ref)
        && (!(x ? rev) || builtins.isString x.rev)
      );
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

  isGitSkill =
    entry:
    (builtins.isString entry && isGitSource entry)
    || (builtins.isAttrs entry && entry ? source && isGitSource entry.source);

  # Validate that a skill name contains only safe characters for shell interpolation.
  # Matches: letters, digits, dots, underscores, hyphens.
  isValidSkillName = name: builtins.match "[a-zA-Z0-9._-]+" name != null;

  storeSkills = builtins.filter (e: !isGitSkill e) cfg.skills;
  gitSkillEntries = builtins.filter isGitSkill cfg.skills;

  # Whether any git skill source uses an SSH URL.
  hasSSHSkills = builtins.any (
    e:
    let
      src = if builtins.isString e then e else e.source or "";
    in
    isSSHSource src
  ) gitSkillEntries;

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

  # Normalize a store skill entry into { path, include, exclude }
  # Handles: bare paths, bare derivations, and { source; include?; exclude?; }
  normalizeStoreSkill =
    entry:
    if builtins.isAttrs entry && entry ? source then
      {
        path = entry.source;
        include = entry.include or null;
        exclude = entry.exclude or null;
      }
    else
      {
        path = entry;
        include = null;
        exclude = null;
      };

  # Normalize a git skill entry into { source, ref, rev, include, exclude }
  # Handles: bare URL strings and { source; ref?; rev?; include?; exclude?; }
  normalizeGitSkill =
    entry:
    if builtins.isString entry then
      {
        source = entry;
        ref = "";
        rev = "";
        include = null;
        exclude = null;
      }
    else
      {
        source = entry.source;
        ref = entry.ref or "";
        rev = entry.rev or "";
        include = entry.include or null;
        exclude = entry.exclude or null;
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

  resolvedStoreSkills = map normalizeStoreSkill storeSkills;

  mergedSkills = pkgs.runCommandLocal "merged-ai-agent-skills" { } ''
    mkdir -p $out
    ${lib.concatMapStringsSep "\n" (
      skill:
      let
        filterSnippet = mkSkillFilter { inherit (skill) include exclude; };
      in
      ''
        find "${skill.path}" -name "SKILL.md" -type f | while read -r skillfile; do
          skill_dir="$(dirname "$skillfile")"
          name="$(basename "$skill_dir")"
          ${filterSnippet}
          rm -rf "$out/$name"
          cp -rL "$skill_dir" "$out/$name"
        done
      ''
    ) resolvedStoreSkills}
  '';

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

  cacheDir = "${config.xdg.cacheHome}/nix-ai-agent-skills";

  gitSkillsScript =
    let
      agentDirs = map agentSkillsAbsPath cfg.agents;
      agentDirsStr = lib.concatMapStringsSep " " (d: ''"${d}"'') agentDirs;
      normalizedGitSkills = map normalizeGitSkill gitSkillEntries;

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
                  if ${pkgs.git}/bin/git -C "$_repo" show-ref --verify --quiet "refs/tags/${lib.escapeShellArg entry.ref}" 2>/dev/null; then
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
      ) normalizedGitSkills;

      deploySnippets = lib.concatMapStrings (
        entry:
        let
          urlHash = builtins.hashString "sha256" "${entry.source}#${entry.ref}#${entry.rev}";
          filterSnippet = mkSkillFilter { inherit (entry) include exclude; };
        in
        ''
          if [ -d "${cacheDir}/repos/${urlHash}" ]; then
            find "${cacheDir}/repos/${urlHash}" -name "SKILL.md" -type f | while read -r skillfile; do
              skill_dir="$(dirname "$skillfile")"
              name="$(basename "$skill_dir")"
              ${filterSnippet}
              for _dir in "''${_AGENT_DIRS[@]}"; do
                ln -snf "$skill_dir" "$_dir/$name"
              done
            done
          fi
        ''
      ) normalizedGitSkills;
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
      for _dir in "''${_AGENT_DIRS[@]}"; do
        for _entry in "$_dir"/*; do
          [ -L "$_entry" ] || continue
          case "$(readlink "$_entry")" in
            "${cacheDir}"/*) rm -f "$_entry" ;;
          esac
        done
      done

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
        ]
      );
      default = [ "opencode" ];
      description = "Which AI agents to configure.";
    };

    skills = lib.mkOption {
      type = lib.types.listOf skillType;
      default = [ ];
      description = ''
        Ordered list of skills sources. Each entry is either:

        - A path or derivation (typically a flake input with
          `flake = false`), deployed at build time via Home Manager
          file management.
        - A git URL string (https://, git@, ssh://, etc.), cloned at
          Home Manager activation time as the user.
        - An attrset with `source` (required), plus optional `ref`
          (branch/tag), `rev` (commit SHA), `include` (whitelist),
          and `exclude` (blacklist).

        When `source` is a git URL, the repo is cloned at activation
        time as the current user. SSH-based URLs (`git@`, `ssh://`)
        require `SSH_AUTH_SOCK`; see `programs.ai-agents.sshAuthSock`.
        `ref` and `rev` are only valid for git sources.

        When `source` is a path or derivation, it is resolved at build
        time and deployed via Home Manager file management.

        Attrset entries may optionally include an `include` list (deploy
        only the named skills) or an `exclude` list (deploy all skills
        except the named ones). These are mutually exclusive -- specifying
        both is an error. Skill names correspond to the basename of
        directories containing SKILL.md files within the source.

        Git skills override store skills on name collision. Within each
        group, later entries override earlier ones.

        Skills are discovered recursively, where any SKILL.md files at any
        nested depth are found and their parent directory becomes the
        skill name in the merged output.
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
        };
      };
      default = { };
      description = "OpenCode agent configuration.";
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
        ++ (lib.imap0 (i: entry: {
          assertion = !(builtins.isAttrs entry && (entry ? include) && (entry ? exclude));
          message = "programs.ai-agents.skills[${toString i}]: 'include' and 'exclude' are mutually exclusive; specify one or neither.";
        }) cfg.skills)
        # ref and rev are only meaningful for git sources
        ++ (lib.imap0 (i: entry: {
          assertion =
            !(
              builtins.isAttrs entry
              && entry ? source
              && (entry ? ref || entry ? rev)
              && !(isGitSource entry.source)
            );
          message = "programs.ai-agents.skills[${toString i}]: 'ref' and 'rev' are only valid for git sources.";
        }) cfg.skills)
        # bare string entries must be valid git URLs, not arbitrary strings
        ++ (lib.imap0 (i: entry: {
          assertion = !(builtins.isString entry && !isGitSource entry);
          message = "programs.ai-agents.skills[${toString i}]: bare string '${entry}' is not a recognised git URL. Use a path literal or { source = ...; } instead.";
        }) cfg.skills)
        # include/exclude entries must be valid skill names (alphanumeric, dots, underscores, hyphens)
        ++ (lib.concatLists (
          lib.imap0 (
            i: entry:
            let
              includeNames = if builtins.isAttrs entry && entry ? include then entry.include else [ ];
              excludeNames = if builtins.isAttrs entry && entry ? exclude then entry.exclude else [ ];
            in
            (lib.imap0 (j: name: {
              assertion = isValidSkillName name;
              message = "programs.ai-agents.skills[${toString i}].include[${toString j}]: '${name}' contains invalid characters. Skill names must match [a-zA-Z0-9._-]+.";
            }) includeNames)
            ++ (lib.imap0 (j: name: {
              assertion = isValidSkillName name;
              message = "programs.ai-agents.skills[${toString i}].exclude[${toString j}]: '${name}' contains invalid characters. Skill names must match [a-zA-Z0-9._-]+.";
            }) excludeNames)
          ) cfg.skills
        ));
      }

      # Store skills deployment (build-time, via Home Manager file management)
      (lib.mkIf (storeSkills != [ ]) {
        # XDG-managed agents (opencode)
        xdg.configFile = lib.listToAttrs (
          map (
            agent:
            lib.nameValuePair agentSkillsPath.${agent} {
              source = mergedSkills;
              recursive = true;
            }
          ) (builtins.filter isXdgAgent cfg.agents)
        );

        # Home-managed agents (claude, cursor)
        home.file = lib.listToAttrs (
          map (
            agent:
            lib.nameValuePair agentSkillsPath.${agent} {
              source = mergedSkills;
              recursive = true;
            }
          ) (builtins.filter (a: !isXdgAgent a) cfg.agents)
        );
      })

      # Git skills deployment (activation-time, as user)
      (lib.mkIf (gitSkillEntries != [ ]) {
        home.activation.deployGitSkills = lib.hm.dag.entryAfter [ "linkGeneration" ] gitSkillsScript;
      })

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
    ]
  );
}
