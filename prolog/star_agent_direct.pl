:- module(star_agent_direct,
          [ direct_turn/2,
            approvals/1,
            approve/2,
            deny/2,
            shutdown/0
          ]).

/** <module> Thin adapter to the *actual* prolog-rlm direct runtime.

The model does not own Star-KB knowledge, authority, executable goals, or
tool schemas. Star-KB remains the symbolic system in both modes. RLM direct is
loaded lazily, so symbolic mode needs no model runtime or model credentials.
*/

:- use_module(star_agent_catalog).
:- use_module(star_agent_effect).
:- use_module(star_agent_kb).

:- dynamic installed_registry/1.
:- dynamic attached_effect_store/1.

rlm_root(Root) :-
    ( getenv('PROLOG_RLM_ROOT',Root) -> true
    ; throw(error(prolog_rlm_not_configured,_)) ).

load_rlm :-
    rlm_root(Root),
    directory_file_path(Root,'prolog/rlm_direct.pl',Direct),
    directory_file_path(Root,'prolog/rlm_tool.pl',Tool),
    directory_file_path(Root,'prolog/rlm_chain.pl',Chain),
    ( exists_file(Direct), exists_file(Tool), exists_file(Chain)
    -> load_files([Tool,Chain,Direct],[if(changed),silent(true)])
    ; throw(error(prolog_rlm_files_missing,_)) ).

ensure_registry(Registry) :-
    installed_registry(Registry), !.
ensure_registry(Registry) :-
    load_rlm,
    rlm_tool:tool_registry_create(Registry),
    catch(
      ( forall(tool_spec(Name,Effect,Description,Fields),
               register_tool(Registry,Name,Effect,Description,Fields)),
        maybe_effect_store,
        assertz(installed_registry(Registry)) ),
      Exception,
      ( catch(rlm_tool:tool_registry_destroy(Registry),_,true),
        throw(Exception)) ).

register_tool(Registry,Name,Effect,Description,Fields) :-
    ( Name == kb_query
    -> Properties=_{operation:_{type:string},
                     arguments:_{type:object,additional_properties:true}},
       Required=[operation,arguments]
    ; findall(Field-_{type:string},member(Field,Fields),Pairs),
      dict_pairs(Properties,_,Pairs), Required=Fields ),
    Schema=tool_schema{
        name:Name,description:Description,
        capability:tool(Name),effect:Effect,
        arguments:_{type:object,properties:Properties,
                    required:Required,additional_properties:false},
        result:_{type:any},
        limits:_{time_limit:48.0,max_output_bytes:32768}},
    Handler=tool_handler(star_agent_direct:preflight(Name),
                         star_agent_direct:dispatch(Name)),
    rlm_tool:tool_register(Registry,Schema,Handler,Outcome),
    ( Outcome=ok(_) -> true
    ; throw(error(tool_registration_failed(Name,Outcome),_)) ).

preflight(Name,Args,Args,operation_details{target:Target}) :-
    tool_spec(Name,_,_,Fields),
    is_dict(Args),
    forall(member(Field,Fields),
           (get_dict(Field,Args,V),
            (Field == arguments -> is_dict(V)
            ; string(V),string_length(V,N),between(1,4096,N)))),
    (get_dict(target,Args,Target0) -> Target=Target0
    ; get_dict(url,Args,Target0) -> Target=Target0
    ; Target=none).

dispatch(kb_query,Args,Reply) :- !,
    star_agent_kb:kb_query(Args,Reply),
    ensure_success(kb_query,Reply).
dispatch(Name,Args,Reply) :-
    star_agent_effect:effect_call(Name,Args,Reply),
    ensure_success(Name,Reply).

ensure_success(_,Reply) :- Reply.status == "ok", !.
ensure_success(Name,Reply) :-
    (get_dict(code,Reply,Code)->true;Code=unknown_failure),
    throw(error(star_agent_effect_failed(Name,Code),_)).

maybe_effect_store :-
    getenv('STAR_AGENT_RLM_EFFECT_STORE',File),
    File \== "", !,
    rlm_root(Root),
    directory_file_path(Root,'prolog/rlm_effect.pl',FileModule),
    load_files(FileModule,[if(changed),silent(true)]),
    rlm_effect:rlm_effect_store_open(File),
    assertz(attached_effect_store(File)).
maybe_effect_store.

direct_capabilities(Caps) :-
    Reads=[tool(kb_query),tool(web_search),tool(web_fetch),
           tool(web_explore),tool(intel_search),tool(actors),
           context(peek),context(search)],
    ( attached_effect_store(_),
      getenv('STAR_AGENT_DIRECT_EFFECTS',Yes),Yes == '1'
    -> append(Reads,[tool(target_create),tool(osint_run)],Caps)
    ; Caps=Reads ).

configured_provider(Name,Provider) :-
    ( getenv('STAR_AGENT_RLM_ENDPOINT',URL), URL \== ""
    -> (getenv('STAR_AGENT_RLM_MODEL',Model),Model \== ""
       -> true ; throw(error(rlm_model_not_configured,_))),
       rlm_chain:openai_compatible_provider(URL,none,Model,Provider),
       Name=openai_compatible
    ; getenv('OPENROUTER_API_KEY',Key), Key \== ""
    -> (getenv('STAR_AGENT_RLM_MODEL',Model),Model \== ""
       -> true ; Model='openrouter/free'),
       rlm_chain:openrouter_provider(Model,Provider), Name=openrouter
    ; throw(error(rlm_provider_not_configured,_)) ).

direct_turn(Prompt,Reply) :-
    catch(direct_turn_checked(Prompt,Reply),Error,failed(Error,Reply)).

direct_turn_checked(Prompt,Reply) :-
    ensure_registry(Registry),
    configured_provider(Name,Provider),
    direct_capabilities(Caps),
    Options=[provider(Provider),provider_name(Name),
             tool_registry(Registry),capabilities(Caps),
             authority_context(session(star_agent)),
             prompt_compile_mode(all_tools),
             budget(_{max_model_calls:6,max_tool_calls:8,
                      max_context_ops:5,max_total_tokens:22000,
                      max_cost_usd:0.3,max_output_bytes:16000,
                      time_limit:150.0}),
             planner_max_tokens(1200),temperature(0)],
    Context=text("Star-Agent is a Star-KB symbolic reasoning client. For assertions about graph entities consult kb_query, prefer analyze/packet/explain and preserve provenance. A missing relation is not evidence of falsity. Never invent StarIntel receipts or actor results. Only registered and capability-permitted tools are executable."),
    rlm_direct:rlm_direct(Prompt,Context,Options,Outcome),
    ( Outcome=ok(Result)
    -> Reply=json{status:"ok",mode:"direct",text:Result.value,
                  modelCalls:Result.turns,toolCalls:Result.tool_calls}
    ; Reply=json{status:"error",mode:"direct",
                 code:"rlm_direct_failure",
                 message:"prolog-rlm direct returned an unsuccessful outcome"} ).

failed(_,json{status:"error",code:"direct_unavailable",
              message:"prolog-rlm direct is unavailable or rejected the request; symbolic mode remains usable"}).

approvals(Reply) :-
    ( installed_registry(_)
    -> rlm_authority:rlm_pending_approvals(session(star_agent),Items),
       maplist(approval_summary,Items,Summaries)
    ; Summaries=[] ),
    Reply=json{status:"ok",pending:Summaries}.

approval_summary(Item,json{approvalId:Text,state:State}) :-
    atom_string(Item.id,Text), atom_string(Item.state,State).

approve(IdText,Reply) :-
    decision(approve,IdText,Reply).
deny(IdText,Reply) :-
    decision(deny,IdText,Reply).

decision(What,IdText,Reply) :-
    ( installed_registry(_),string(IdText),
      atom_string(Id,IdText),
      rlm_authority:rlm_pending_approval(session(star_agent),Id,Record),
      Record.state == pending
    -> (What==approve
       -> rlm_authority:rlm_approve(Id,Outcome)
       ; rlm_authority:rlm_deny(Id,operator_denied,Outcome)),
       (Outcome=ok(_) -> Status="ok" ; Status="error"),
       Reply=json{status:Status,approvalId:IdText,action:What}
    ; Reply=json{status:"error",code:"unknown_pending_operation"} ).

shutdown :-
    ( retract(installed_registry(Registry))
    -> catch(rlm_tool:tool_registry_destroy(Registry),_,true)
    ; true ),
    ( retract(attached_effect_store(_))
    -> catch(rlm_effect:rlm_effect_store_close,_,true)
    ; true ).
