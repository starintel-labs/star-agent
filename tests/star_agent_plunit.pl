:- begin_tests(star_agent).

:- use_module('../prolog/star_agent_commands').
:- use_module('../prolog/star_agent_repl').

test(symbolic_unknown_does_not_call_model) :-
    run_command("tell me everything about the world",symbolic,Result),
    assertion(Result.status == "error"),
    assertion(Result.code == "unsupported_symbolic_intent").

test(typed_target_parse) :-
    interpret("target reddit r/example --dataset test-set",symbolic,
              effect(target_create,Args)),
    assertion(Args.actor == "reddit"),
    assertion(Args.target == "r/example"),
    assertion(Args.dataset == "test-set").

test(named_kb_query) :-
    interpret("kb neighbors starintel:device:radio-1",symbolic,kb(Request)),
    assertion(Request.operation == "neighbors"),
    assertion(Request.arguments.id == "starintel:device:radio-1").

test(star_kb_intent_routes_to_existing_kb) :-
    interpret("what is known about starintel:device:radio-1",symbolic,
              kb(Request)),
    assertion(Request.operation == "analyze").

test(mode_direct_does_not_infer_agentic_planner) :-
    interpret("mode direct",symbolic,mode(direct)).

test(direct_model_only_when_explicit) :-
    interpret("Inspect this query",direct,direct("Inspect this query")).

test(help_without_external_services) :-
    execute_line("help",symbolic,Reply),
    assertion(Reply.status == "ok").

test(status_reports_actual_symbolic_engine) :-
    execute_line("status",symbolic,Reply),
    assertion(Reply.symbolicEngine == "star-kb").

test(unsupported_kb_operation_never_compiles_user_goal) :-
    interpret("kb call(system('bad'))",symbolic,unsupported(_)).

:- end_tests(star_agent).
