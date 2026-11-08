Universal Bank SMS Parser
====================

License: GNU Affero General Public License v3.0 (see LICENSE).

The rules and conformance corpus include formats adapted from PennyWise
parser-core at ed9d6f5014375f195fe327019768bc76ea98e92e, and from the
simple_money_sms_parser Dart port. Upstream:
https://github.com/sarim2000/pennywiseai-tracker

Upstream-derived rules and fixtures retain their original authors' copyright.
Source-derived examples and deliberate differences are labelled in the corpus.
The portable interpreter and compiler are SimpleMoney-specific implementations
distributed under the same AGPL-3.0 license.

The Indian migration includes 54 upstream bank/payment-service families through
the legacy Dart regression corpus. `ported.json` records the originating test
file or source-derived provenance. `variables.json` and generated entries in
`rejections.json` are synthetic regressions, not upstream or user-submitted SMS.
Legacy rejected literals are labelled separately. The original test files retain
their upstream attribution. `legacyDifferences` documents corrected merchant
extraction and the erroneous `unded` reference previously extracted from
`refunded`; these annotations preserve the historical comparison. Current tests
check the standalone engine against the shared conformance corpus.
