# Cohort tool and experience compatibility

Sealed releases retain their original tool catalog, component snapshots and digests. The runtime checks a release against an explicitly supported complete catalog, then checks every required operation version and module definition against the running application. Unrelated additional runtime tools do not invalidate historical releases. A missing handler, changed version, incorrect handler key, changed required module or unrecognized sealed catalog fails closed.

## Supported contracts

| Tool contract | Experience schemas | Meaning |
| --- | --- | --- |
| 1 | 1 | Literal pre-pilot catalog: eight modules and forty operation keys, each at version 1. |
| 2 | 1, 2 | The same existing tools, with explicit support for the versioned experience mode. This does not claim savings-ledger operations exist. |

`CohortReleases::ToolContracts` owns the immutable catalog literals. `Contract.tool_registry_snapshot(version:)` returns a canonical copy. `Contract.runtime_tool_registry_snapshot` inspects the actual registered handler keys/versions and module definitions. Compatibility requires the sealed snapshot to equal a complete known catalog; a rehashed arbitrary subset, extra operation or duplicated entry is not authorized.

Schema 1 configurations continue to select contract 1. Their default configurations, canonical normalization, digests and participant capability payload remain unchanged. Schema 2 selects contract 2 and requires `experience_mode` to be `savings_challenge` or `household_cfo`, alongside the existing boolean optional-module settings. There is no implicit upgrade. Publishing the mode uses the existing preview, immutable version and release process.

The schema 2 participant payload adds `experience_mode` and reports `schema_version: 2`. Released participant capabilities enumerate the modules in their sealed catalog, so an unrelated new core module cannot silently appear for an older release. Unsealed safe and standalone defaults retain their existing behavior. The focused savings navigation, enrollment, ledger, privacy grants and daily workflows are separate implementation slices; publishing this configuration alone does not establish pilot readiness.

## Adding or changing tools

1. Preserve every supported catalog already used by a release. Add another literal catalog version and explicitly select it for the intended experience. Never derive published catalogs automatically from the live registry.
2. Declare the exact operation key/version and module definition in the new catalog. Add complete-catalog and old/new runtime compatibility tests. Required module definitions include labels and unavailable messages, so changing those values needs an intentional contract/runtime decision.
3. A semantic operation change must increment its operation version. The current household operation dispatcher supports only the handler's declared version; a bump therefore makes older catalogs requiring that version incompatible. Preserve a reviewed versioned handler/dispatcher before claiming older operations remain supported. Catalog history alone does not preserve old behavior.
4. Additional registered operations may coexist with historical catalogs, but they are not added to those sealed snapshots. This compatibility mechanism is not a participant authorization grant. New tools still require their domain authorization, consent and review boundaries.

Contract compatibility checks declared handler keys and versions; it cannot detect an implementation changed without its required version bump. Engineering review and semantic tests remain necessary.

## Restore, rollout and cache

Bundle, release and studio registry versions derive from the candidate/source snapshot. Restoring a contract 1 release after publishing schema 2 produces a new governed record carrying contract 1; it never labels old evidence with the current candidate's version. Existing rollout and rollback authorization stays in force.

The runtime integrity cache fingerprints the actual registry, supported catalog definitions and sealed release attributes. A previously positive entry cannot conceal a missing/bumped handler, changed module definition or mutated in-memory sealed payload. Unsupported runtime state remains a safe fallback.

Focused regression coverage is in `cohort_releases_tool_contracts_test.rb`, `cohort_experience_schema_test.rb` and `cohort_release_contract_versions_test.rb`. It includes frozen historical digests, malformed/self-consistent forged catalogs, unrelated additions, incompatible handlers/modules, cache invalidation, schema publication and rollback, and a governed legacy-to-savings rollout/rollback/restore. Existing canonical manifest and release-governance suites remain required.
