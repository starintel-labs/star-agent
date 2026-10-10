:- module(star_agent_catalog,
          [ tool_spec/4,
            public_tool/1
          ]).

/** <module> Star-Agent external capability catalog

This is transport metadata. Star-KB owns knowledge, predicates, and ontology;
prolog-rlm owns the optional model direct runtime. Merely declaring a tool does
not grant a capability or execution authority.
*/

tool_spec(kb_query, read,
          "Query actual Star-KB exported reasoning predicates against the configured StarIntel projection",
          [operation,arguments]).
tool_spec(web_search, read,
          "Search using the operator-configured SearXNG JSON API", [query]).
tool_spec(web_fetch, read,
          "Fetch and summarize a bounded public HTTP(S) document", [url]).
tool_spec(web_explore, read,
          "Explore same-origin links on a bounded public website", [url]).
tool_spec(intel_search, read,
          "Search authenticated StarIntel documents using the discovered documents.search contract", [query]).
tool_spec(actors, read,
          "Discover installed StarIntel pro-actors from trusted manifests", []).
tool_spec(target_create, network_write,
          "Create a scoped StarIntel actor target using the manifest-advertised sa-actor CLI", [actor,target,dataset]).
tool_spec(osint_run, process,
          "Run an explicitly allowlisted bounded OSINT executable", [tool,target]).

public_tool(Name) :-
    tool_spec(Name, _, _, _).
