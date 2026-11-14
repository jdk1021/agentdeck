# Provider display order

Provider and model lists share a consistent presentation order across the app and CLI. Display groups
are defined in `Sources/AgentDeckCore/ProviderDisplayOrder.swift`. Collection, sign-in, account selection,
and request routing are unchanged.

The group boundary takes precedence over usage, readiness, or alphabetical sorting in the menu panel,
dashboard, settings pickers, collector toggles, CLI output, and shared usage output. Within a group,
each view keeps its usual sorting. Model usage tables recognize model families, including names
prefixed by a model router, so that their ordering stays consistent with provider lists.
The website and support tables follow the same grouping. The upstream collector inventory retains
its original order and provenance.

The screenshot examples are Claude Code, Codex, then Grok. OpenRouter demonstrates prepaid balances.
The settings key picker starts with Grok.
