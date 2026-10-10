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


:- dynamic fake_model_call/1.

fake_model(Request, ok(Response)) :-
    ( retract(fake_model_call(N0)) -> true ; N0=0 ),
    N is N0+1,
    assertz(fake_model_call(N)),
    ( N =:= 1
    -> atom_json_dict(Arguments,
           _{operation:"neighbors",arguments:_{id:"starintel:device:radio-1"}},
           [width(0)]),
       atom_string(Arguments,ArgumentString),
       Calls=[_{id:"kb_1",type:"function",
                function:_{name:"kb_query",arguments:ArgumentString}}],
       Content=""
    ; member(Message,Request.messages),
      Message.role == tool,
      Message.tool_call_id == "kb_1",
      Calls=[],
      Content="REAL_STAR_KB_TOOL_EXECUTED"
    ),
    format(string(Id),"star-agent-fake-~d",[N]),
    ( Calls == [] -> Finish=stop ; Finish=tool_calls ),
    Response=model_response{
        provider:fake,requested_model:fake,selected_model:fake,
        response_id:Id,
        assistant:message{role:assistant,content:Content,
                          tool_calls:Calls,reasoning:"",reasoning_details:[]},
        text:Content,tool_calls:Calls,reasoning:"",reasoning_details:[],
        finish_reason:Finish,
        usage:usage{present:true,prompt_tokens:2,
                    completion_tokens:1,total_tokens:3,cost:0.0},
        metadata:provider_metadata{provider:fake,http_status:200,
                                   response_received:true}}.

test(real_rlm_native_direct_tool_loop_without_paid_provider,
     [condition((getenv('PROLOG_RLM_ROOT',_),getenv('STAR_KB_ROOT',_)))]) :-
    star_agent_direct:ensure_registry(Registry),
    retractall(fake_model_call(_)),
    Options=[provider(provider(openai_compatible,[])),
             provider_name(openai_compatible),
             model_handler(plunit_star_rlm_integration:fake_model),
             tool_registry(Registry),
             capabilities([tool(kb_query),context(peek)]),
             prompt_compile_mode(all_tools),
             budget(_{max_model_calls:4,max_tool_calls:2,
                      max_context_ops:2,max_total_tokens:5000,
                      max_cost_usd:0.1,max_output_bytes:8192,
                      time_limit:25.0}),
             planner_max_tokens(512),temperature(0)],
    rlm_direct:rlm_direct("Use kb_query for the radio's neighbors.",
                          text("synthetic corpus"),Options,Outcome),
    assertion(Outcome=ok(_)),
    Outcome=ok(Result),
    assertion(Result.value == "REAL_STAR_KB_TOOL_EXECUTED"),
    assertion(Result.tool_calls =:= 1).

:- end_tests(star_rlm_integration).
