# Changelog

## [0.2.0](https://github.com/IsmaelMartinez/delegate-to-ollama/compare/v0.1.0...v0.2.0) (2026-05-07)


### Features

* AAIF-compliant symlink at .agents/skills/delegate-to-ollama ([#24](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/24)) ([1413ee2](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/1413ee2dc45ec9b1c3bc9ae8d4773b61ebc88fea))
* add --dry-run mode to pick-model.sh (Phase 4) ([#16](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/16)) ([6ab8470](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/6ab8470f0b2f5a5bd2ad8416b3373233defdd2e6))
* experiment-runner telemetry in the Phase 8 metrics rollup ([#34](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/34)) ([b356b29](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/b356b29b3f458df9a642ae9a5705e259f2994a6c))
* free Ollama backend for trigger-eval gate ([#44](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/44)) ([dbc61c5](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/dbc61c517328d5d85738f8d7c66f80486e687519))
* GitHub Models backend + CI gate enforcement ([#47](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/47)) ([f3875e9](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/f3875e9aa4df12178a3ec5a0187b16366beb90d3))
* **mcp:** surface external links — pick_model.url + list_related_projects ([#23](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/23)) ([f52f5b3](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/f52f5b32466f8cdebc27cb48b662fe6fce856452))
* Phase 2 hardening — validation pipeline ([#8](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/8)) ([4309d2f](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/4309d2f849909f445c06828b2cc2cf255240f9ae))
* Phase 3 distribution — Claude Code plugin manifest and CODEOWNERS ([#11](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/11)) ([3c084d9](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/3c084d93057ea290bccddd88cfc843c4fa628340))
* Phase 5 ecosystem integration — MCP server + roadmap close-out ([#21](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/21)) ([527fe86](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/527fe86ef6fedcb03c6078563cbe7ce000dd92d9))
* Phase 7 follow-ups — frontmatter not-fit line and runner polish ([#10](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/10)) ([a2385cb](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/a2385cb89c2a2cecfd6c68a82e76b9506418201a))
* Phase 7 rigour tooling — reps, mechanical T3 scoring, single-regime, dated T3 fixture ([#19](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/19)) ([6b8e488](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/6b8e48824378f7f11f514fa956b5b8b92e859b51))
* Phase 8 observability — delegate.sh wrapper and metrics summary ([#9](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/9)) ([407ad18](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/407ad183687031a1418c9676e162ccfc12da9aab))
* Phase 9 v1 personalisation + delegation discipline + 2026-05-03 retrospective ([#25](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/25)) ([3129a90](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/3129a90d657b48594e0dccc9a5aba05f1e5ab123))
* release-please pipeline for tagged releases + CHANGELOG ([#50](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/50)) ([b398334](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/b3983342d4bd6864a82cec29c44f1e40f4524be2))
* scaffold Phase 4 tiers (vision, embedding, premium-general, reasoning-vision) ([#17](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/17)) ([1534f35](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/1534f35251797e6f4bb8077ef602f5b8b9e8887c))
* switch delegate.sh from ollama run CLI to /api/generate HTTP API ([#31](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/31)) ([48c0d33](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/48c0d33f57105aa2f29d74e52c691ab7c481e887))
* v6 — deepseek-r1:32b at 19GB hits Opus parity, promote in reasoning tier ([#27](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/27)) ([ebec7dd](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/ebec7dda7aa58adcadf925c072996c8f6d17a7a2))
* v7 confirms directive-rule pattern is task-agnostic ([#29](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/29)) ([2fa62e2](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/2fa62e272d5c24c3d866752dfb343cdafc892dab))
* v8 probes code-generation delegation under SEARCH/REPLACE format ([#33](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/33)) ([4f1a220](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/4f1a2203163b00b496ce5aa35588c968bd55f141))


### Bug Fixes

* resolve None==None severity comparison in scorer-v2 and v3 ([#28](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/28)) ([6c1d606](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/6c1d606874b1f776cc8f16405d0cbfc14ea8b6eb))
* vision and embedding call-shapes use HTTP API, not non-existent CLI subcommands ([#18](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/18)) ([33a40f1](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/33a40f162322e016e8c689b75c4dabb53113ec80))


### Documentation

* 2026-05-01 baseline (5 models × 3 reps × 3 tasks, mechanical T3) ([#20](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/20)) ([af9eca1](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/af9eca1d3a4e6a092ef53594f86c766893feb30c))
* add ADRs 0001-0003 (Phase 2 deferred ADRs) ([#15](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/15)) ([8a2439c](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/8a2439cbd9fd6b678a3fa38c810425f88ad33dcb))
* add CLAUDE.md with repo-as-skill orientation ([#5](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/5)) ([e684e98](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/e684e98ac1a34d0a99bfbddaa815eb44b5d916e0))
* add next-session priorities to ROADMAP ([#32](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/32)) ([efd8df5](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/efd8df55d7d84888664a2f161f4f378d8cee6a05))
* add Phase 8 (observability and feedback) to roadmap ([#6](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/6)) ([6b2affd](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/6b2affd5b8fb11f0c1ae028fb47a213b39938e7b))
* add Related projects section (Phase 5 cross-links) ([#14](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/14)) ([73cc5d4](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/73cc5d464d27d94f37a9309186ffe194ffb1e66a))
* add ROADMAP with hardening from plg-agent-skills ([2033df2](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/2033df278f93e30385e9f432badeef972f7f19f2))
* clean merge-conflict markers from ROADMAP + Done→Now→Next diagram + helper item ([#41](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/41)) ([e2f3b8f](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/e2f3b8f85e00bf31d5e1a8b47e84235e2d11f3ce))
* community health files for going-public readiness ([#49](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/49)) ([061dc6d](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/061dc6d1718a6d7d4f0752cb6a46f92434202172))
* document non-interactive output capture (refs [#3](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/3)) ([#4](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/4)) ([fdfb026](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/fdfb026e249b61a5bde067a6f0eea9b439740e30))
* fold v8 + adversarial-chain findings into SKILL.md + honest cost section in README ([#40](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/40)) ([0990bc0](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/0990bc0becf7da3c2d470dafa13a193cd0a6fc7e))
* per-tool install guides ([#46](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/46)) ([0e084d4](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/0e084d4c3cbb338e5d5fab096bddc9a83bac0f94))
* Phase 5 follow-up — surface external links in MCP tool responses ([#22](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/22)) ([4f9989e](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/4f9989ebc7a38fd7f8215e839751e2d0efbede31))
* queue baseline-rigour follow-ups in roadmap ([#2](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/2)) ([f262bca](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/f262bca7cfd703c372f74d123266786bedc66264))
* scope commit-message Fits to single-file changes (closes [#3](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/3)) ([#7](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/7)) ([a539804](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/a5398046c5b08d19fdfda251d375d1cd954a018b))
* SKILL.md edits from plg-tech-cloudfront-waf field notes ([#43](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/43)) ([45cd0c5](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/45cd0c56aac6b3a6ed91198bf7751b5ee654011d))
* sweep ROADMAP to mark items shipped in PRs [#1](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/1), [#8](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/8)-[#11](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/11) ([#13](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/13)) ([fd24f0e](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/fd24f0e22f9c989418415d5ad637dfe149ff2687))
* sync ROADMAP 'Recently completed' block with PR [#41](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/41) ([#42](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/42)) ([7ade40c](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/7ade40c2b987f4ae25ecb5cb0a0d653e75980fbe))
* sync ROADMAP after PRs [#43](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/43) and [#44](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/44) ([#45](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/45)) ([e958be8](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/e958be8a2282375d52d4dc7d65521f9b2e5a7f6f))
* sync ROADMAP after PRs [#45](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/45), [#46](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/46), and [#47](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/47) ([#48](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/48)) ([d1b82c3](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/d1b82c3b09131fcf58c4b140d87fd13bd49c8bfa))


### Maintenance

* Claude Code config — permissions allowlist, post-edit hook, CLAUDE.md update ([#12](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/12)) ([95645d2](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/95645d2bba459aaf8c40cea47c58cd36b26d5786))
* fix curl bug in runners and add shared helper ([#30](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/30)) ([c76a34f](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/c76a34fce4e81de069fbf128cd7daff53928ea24))
