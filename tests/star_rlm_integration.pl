:- begin_tests(star_rlm_integration).

:- use_module('../prolog/star_agent_direct').
:- use_module('../prolog/star_agent_kb').

test(real_prolog_rlm_registry_and_star_kb_tool,
     [condition((getenv('PROLOG_RLM_ROOT',_),getenv('STAR_KB_ROOT',_)))]) :-
    star_agent_direct:ensure_registry(Registry),
    rlm_tool:tool_discover(Registry,Schemas),
    member(Schema,Schemas),
    Schema.name == kb_query,
    rlm_tool:tool_invoke(
        Registry,[tool(kb_query)],kb_query,
        _{operation:"neighbors",arguments:_{id:"starintel:device:radio-1"}},
        [],Outcome,Trace),
    assertion(Trace.authorization == allowed),
    assertion(Outcome = ok(_)).

test(unconfigured_direct_write_not_capability,
     [condition(getenv('PROLOG_RLM_ROOT',_))]) :-
    star_agent_direct:direct_capabilities(Caps),
    assertion(\+ memberchk(tool(target_create),Caps)).

:- end_tests(star_rlm_integration).
