"""API005 re-land (D-G6v2, m3): handler declares a route whose local
openapi.json requires a request body but never reads it.

ISOLATED FIXTURE DIRECTORY — this file's openapi.json lives next to it
(tests/conformance/api_contract_body/openapi.json), never in
tests/conformance/ itself. The prior API005 fixture was withdrawn at Wave C
close because its author's openapi.json overwrote the tracked corpus
openapi.json that tests/conformance/api_contract.py's API001/API002 depend
on (a file with incident history — the lead's cleanup afterward briefly
deleted the tracked file too). find_openapi_spec (api_contract_check.odin)
resolves relative to the checked file's OWN directory, so this fixture's
spec can never collide with the corpus one.
"""
from mimir.http import route, Request, Response


@route("POST", "/items")
def create_item(req: Request) -> Response:  # API005 is Warning, not caught by marker (matches
    # api_contract.py's documented convention for API002-API004 — conform's
    # Check-pass marker matching only counts Error severity; API005 firing is
    # proven directly via `mimir check` output and the every-code-fires gate,
    # not conform. See tests/scripts/registry_reinit_test.py's sibling
    # evidence pattern; this file itself is the permanent fixture.
    return Response(body={"id": 1})
