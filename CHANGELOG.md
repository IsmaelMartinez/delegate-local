# Changelog

## [0.3.0](https://github.com/IsmaelMartinez/delegate-to-ollama/compare/v0.2.1...v0.3.0) (2026-05-21)


### Features

* add prompt-pattern issue template for Layer 4 feedback loop ([#84](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/84)) ([3b5ffa4](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/3b5ffa42cd0d9972e4f18e87b9a0eabfacf1e6ec))
* add recommend_prompt MCP tool — closes Layer 3 of training-loop initiative ([#83](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/83)) ([7b6481b](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/7b6481b7b836ad2d801a64d18bb734712a7fa10d))
* audit-metrics script for periodic MISS-bucket review ([#88](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/88) option B) ([#100](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/100)) ([bf0dc66](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/bf0dc660fb2064c39a5befadba01bf764d46a65a))
* batch trigger-eval scoring into a single API call (closes [#62](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/62)) ([#66](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/66)) ([d404c46](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/d404c46e052be2a01b9fa79e55cf4b27536f065c))
* DELEGATE_BACKEND defaults to auto (probes MLX, falls back to Ollama) ([#116](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/116)) ([63243a5](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/63243a5cd6b268e8dc040d8f09c472ca09bd9bef))
* delegate-meta stderr + worktree-aware frontmatter check ([22a5eff](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/22a5effbff0a47ed2144027b7d21157d5e64a61f))
* delegate.sh --recipe NAME and --var key=value flags ([#73](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/73)) ([3723476](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/372347636caa498791fb1ff7da287513786549ac))
* em-dash-removal recipe (closes [#107](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/107)) ([#109](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/109)) ([fbe8539](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/fbe8539890665192b4dfed5a4b7c6148c35d6865))
* expand recipe library to 6 — meets Layer 3 gate ([#81](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/81)) ([ce5fc8b](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/ce5fc8b4d3600deac615296ecccc830a932b3841))
* expand recipe library with summarise-diff and pr-review-reply ([#80](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/80)) ([299d090](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/299d09017450fa403ccfee2dc359e0242d01d0a0))
* file-summary subject directive + polish-reply opener anti-padding ([#98](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/98)) ([384e0e8](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/384e0e83db8ac9982951c1abd98f955e0f2165d7))
* MCP pick_model tool gains a backend parameter ([#108](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/108)) ([796253b](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/796253b0cbaf0dbd1b9a76a8c9651f3f24e79fcf))
* MLX backend posts to /v1/chat/completions ([#112](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/112)) ([36ed35b](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/36ed35b178be772f717729964530dba0e266e057))
* MLX backend scaffolding (DELEGATE_BACKEND=mlx) ([#105](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/105)) ([6eb1708](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/6eb1708bfb68a1a7404d06f45f6ab83a4fcd4b14))
* monthly-audit-reminder workflow for audit-models tracking ([#99](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/99)) ([74acfd1](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/74acfd113d9b84fbec598a065d6c705789f123be))
* P1 restraint probe — restraint splits into verbosity + anchoring axes ([#122](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/122)) ([1eb6d04](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/1eb6d04219112561abd4779af03c0167b805b0a6))
* per-backend metrics rollup and MLX install guide ([#106](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/106)) ([b8ec8c2](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/b8ec8c2b07927876a24c92acb718c077f4fbc1f7))
* pre-flight canary on delegate.sh --recipe — close [#110](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/110) ([#129](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/129)) ([1712c99](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/1712c993c3e675576a0f150f0daaa0f31a819a0e))
* prompts/ library with commit-message and pr-description recipes ([#72](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/72)) ([077c790](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/077c790a9c78f62c85d1af993c890aa22f28210b))
* prompts/ci-log-triage.md — first input-digestion recipe ([#124](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/124)) ([29e8d32](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/29e8d32ec2a2938c890eb975b7fb0edfcae8522b))
* prompts/doc-section.md — close closing-recap MISS issue ([d4f0fcf](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/d4f0fcf695af1509d8c53a9b5057be19dd8b30e7))
* prompts/roadmap-entry.md — graduate issue [#125](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/125) into recipe ([#128](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/128)) ([2e97c75](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/2e97c75a3247cc19be0ebe2a78521846d8168945))
* regenerate T4 fixture, confirm MLX 18/18 with closes-the-gap guard ([#119](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/119)) ([802f7ba](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/802f7bafec9f180f34a0b3977b1c329206db6a8c))
* runner defaults to Ollama API path, --ollama-cli opts into legacy ([#118](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/118)) ([e774397](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/e774397888c486dde3769ec18490556983eb54cc))
* scripts/apply-and-test.sh director-side test-runner helper ([#69](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/69)) ([9f0a13e](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/9f0a13e4f4128ee08d972a0d2835aaf3f00e260c))
* scripts/delegate-feedback.sh hit/miss tracking + metrics rollup ([#70](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/70)) ([0c786fa](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/0c786faf98d0c625eab4c8cfd87cb5f51adb51f6))
* T4 closes-the-gap guard, T3 backtick spans, runner --ollama-api ([#114](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/114)) ([152ca65](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/152ca656d8e67b5cfacaa372389300b60ad321ff))
* T4 commit-message fixture + structural-check scorer ([#86](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/86)) ([81e797d](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/81e797d743a4ad87dd715fcca7f4eb41a7fd27f4))
* T5 JSON-shape extraction fixture + scorer (Phase 7 follow-up) ([#94](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/94)) ([5d03b8b](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/5d03b8bf3b5ccb0c24cc6d5474d9238538d4d97e))
* T6 regex-generation fixture + scorer (Phase 7 follow-up) ([#96](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/96)) ([1974836](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/19748367708da9ece988b7c4e7198b48a88ed78d))
* trigger-on-MISS nudge for recurring patterns ([#88](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/88), option A + C) ([#91](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/91)) ([94d4aa3](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/94d4aa34c515a17669af2aafa29b9b8ccd411044))
* verdict nudge on delegate.sh — close the untracked-verdict gap ([#126](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/126)) ([56a4fb8](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/56a4fb8850faa7777ea5e563b43e42148bc1f06f))


### Bug Fixes

* catch declarative-rephrase padding in commit-message recipe + T4 scorer ([#93](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/93)) ([9c40b3e](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/9c40b3ed12818a4aebc80381aabc228eda41e81b))
* commit-message recipe subject-length reinforcement + calibration ([#101](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/101)) ([d4528e0](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/d4528e0118224bd8402c0574d7250e8a9e0b0389))
* delegate-feedback.sh stale-window and --ts pinning (rebased) ([#79](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/79)) ([2b71d99](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/2b71d990b5b6b6f8c1ba1131714a3557daeae0b4))
* pr-description recipe — stall on ~1.5 KB body, update calibration ([#90](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/90)) ([a7043b6](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/a7043b67fff4119fdaf271c23633fb4f90e8d632))
* recipe calibration — anti-padding + long-context-not-faster ([#85](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/85)) ([7273854](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/7273854165d82c631171f74bbf057306f5d459d9))
* strengthen commit-message recipe (#NN) guard with contrastive one-shot ([#78](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/78)) ([bb9167a](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/bb9167a017db035c1d8709ab17c4594e70996f0c))
* trim SKILL.md frontmatter under the 1536-char per-entry cap ([#89](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/89)) ([38080dd](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/38080dddca83568b8ab328f154d5aa3703ae53d4))


### Documentation

* 14-day baseline-staleness cadence backstop ([#130](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/130)) ([d6e5f27](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/d6e5f27685fc89d071c6a14ef36f2a8594941d0c))
* ADR-0005 capturing reasoning-tier ordering rationale ([#59](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/59)) ([62cd6ad](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/62cd6adbe2e88a093c5f65d75a86489db8c78b47))
* ADR-0006 defers multi-tier MLX serving on empirical cost data ([#121](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/121)) ([def8c95](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/def8c95bbc783268d6b487779fb149af8faff928))
* **claude:** add homepage convention ([#64](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/64)) ([088aaf7](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/088aaf7e328774b96c41dfce5f96a71b1768d374))
* promote CI trigger-eval skip-when-unchanged to priority [#1](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/1) ([#63](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/63)) ([baa2be9](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/baa2be9ea68d0ec38ba105de07b130b9852cf438))
* README front-door — define tier on first use, reconcile install path ([#57](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/57)) ([7b9e933](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/7b9e933e59368f6407f8717fd49cf635f7228706))
* record issue [#110](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/110) calibration — model parameter count is the threshold ([#123](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/123)) ([1dea58d](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/1dea58dd18109cb4291b4016cbfcec2cb476f247))
* ROADMAP — add issue [#125](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/125) roadmap-entry recipe as P1 ([#127](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/127)) ([c737daa](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/c737daa413153168bf7ad60b1b01615a8392e8fb))
* ROADMAP — promote embedding to Phase 4 priority, defer vision ([#131](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/131)) ([7d508c5](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/7d508c55e4d4f3e6e8eba9b41a4b5840cbe26a2f))
* ROADMAP mechanical dedup ([#58](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/58)) ([2d5168f](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/2d5168ff391e4b71f58d98060527333b159413be))
* ROADMAP phase restructure — collapse fully-shipped phases ([#60](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/60)) ([669d639](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/669d639dc6627d4a20f153160cee794bd64b11f1))
* sync ROADMAP after [#62](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/62) close + surface dogfooding gap ([#67](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/67)) ([34f8d92](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/34f8d92e9331c3c7be9df1c8c9ca87562d2df6e9))


### CI/CD

* add skip-when-unchanged to trigger-eval steps and bump fetch-depth ([#71](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/71)) ([c28c08c](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/c28c08ccd406473e28c879cfaf525afff94aa47d))
* make GitHub Models trigger-eval advisory until [#62](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/62) ships ([#65](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/65)) ([385eaa8](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/385eaa835ba349dcc6e3d026a72d34ffa2f463a1))


### Testing

* add 4 paraphrase positives reflecting in-session task patterns ([#68](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/68)) ([cc96756](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/cc967562ef406f47a3ec0e444debfa7b5ac91de1))


### Maintenance

* add code-scanning configuration ([#82](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/82)) ([8b8f546](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/8b8f546f273e8e9ef1f639487daae9e7ebbaa07a))
* MLX vs Ollama 2026-05-12 baseline (same Qwen3.6-35B 8-bit) ([#113](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/113)) ([9645e65](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/9645e65132b47f4a3f24a68d679fab4f7a8ed649))
* MLX vs Ollama v2 — apples-to-apples 2026-05-12 baseline ([#115](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/115)) ([5cae7d2](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/5cae7d2dff7898e9096886988383c57adf69c458))
* reconcile CLAUDE.md test counts after parallel PR merge ([#102](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/102)) ([ff8ea8d](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/ff8ea8d201610e1ad0cc88028622f8f370573a12))
* reconcile ROADMAP after audit-models and audit-metrics PRs ([#104](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/104)) ([117fd0c](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/117fd0c7b1c4cd79fffa5ab700834db0d00c1615))
* refresh ROADMAP.md for 2026-05-11 merges and Layer 5 nudge ([#92](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/92)) ([90f493e](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/90f493efa21c1b582ea4a822f0994f9d42e4fcd1))
* ROADMAP — add [#119](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/119) PR ref to T4 entry and line-break finding ([#120](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/120)) ([041eb32](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/041eb327343e7e947fa4ba2853762340363ce7ab))
* ROADMAP — close out MLX track, prioritise five follow-ups ([#117](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/117)) ([ab8fa60](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/ab8fa60863c6e4203593435dee24b30a51b4feca))
* scripts polish — audit-models llmfit cache, mktemp, assertion split ([#61](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/61)) ([9464b2f](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/9464b2f3e2e26b449e9ff24b9efa0c2a9b5d9715))
* surface two recipe-tightening follow-ups in ROADMAP.md ([#103](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/103)) ([442cb0d](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/442cb0db8f87b4e8a85f9cbebd5a1ace6e86687e))

## [0.2.1](https://github.com/IsmaelMartinez/delegate-to-ollama/compare/v0.2.0...v0.2.1) (2026-05-08)


### Documentation

* drift corrections across README, CLAUDE.md, ADR-0003, CONTRIBUTING ([#53](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/53)) ([582b967](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/582b9677f84369579a9c283d245ca529b93f44a5))


### Maintenance

* add repo-butler consumer guide to CLAUDE.md ([#54](https://github.com/IsmaelMartinez/delegate-to-ollama/issues/54)) ([39d2975](https://github.com/IsmaelMartinez/delegate-to-ollama/commit/39d297551e2b19c13f290d112c871cda0681dd75))

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
