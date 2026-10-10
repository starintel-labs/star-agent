:- module(star_agent_kb,
          [ kb_query/2,
            kb_ready/1
          ]).

/** <module> Star-KB is the symbolic AI; this is a bounded adapter only.

No duplicate ontology, knowledge store, or arbitrary goal evaluator lives here.
Only named exported predicates from starintel-labs/star-kb are accessible.
Operator-controlled STAR_KB_ROOT and STAR_KB_PROJECTION designate trusted
Prolog source; neither can be selected by model messages.
*/

:- use_module(library(solution_sequences)).
:- use_module(library(time)).
:- dynamic kb_loaded/2.

kb_ready(Ready) :-
    ( getenv('STAR_KB_ROOT', Root),
      getenv('STAR_KB_PROJECTION', Projection),
      directory_file_path(Root, 'kb/core/star_reasoning.pl', Reasoner),
      exists_file(Reasoner), exists_file(Projection)
    -> Ready = true
    ; Ready = false ).

ensure_kb :-
    getenv('STAR_KB_ROOT', Root),
    getenv('STAR_KB_PROJECTION', Projection),
    kb_loaded(Root, Projection), !.
ensure_kb :-
    ( getenv('STAR_KB_ROOT', Root),
      getenv('STAR_KB_PROJECTION', Projection)
    -> true
    ; throw(error(star_kb_not_configured, _)) ),
    directory_file_path(Root, 'kb/core/star_reasoning.pl', Reasoner),
    ( exists_file(Reasoner), exists_file(Projection)
    -> true
    ; throw(error(star_kb_files_missing, _)) ),
    load_files(Reasoner, [if(changed), silent(true)]),
    star_json:load_projection(Projection),
    retractall(kb_loaded(_, _)),
    assertz(kb_loaded(Root, Projection)).

kb_query(Request, Reply) :-
    catch(kb_query_checked(Request, Reply),
          Error, kb_error(Error, Reply)).

kb_query_checked(Request, Reply) :-
    is_dict(Request),
    get_dict(operation, Request, Operation),
    string(Operation),
    get_dict(arguments, Request, Arguments),
    is_dict(Arguments),
    ensure_kb,
    call_with_time_limit(4,
       kb_decide(Operation, Arguments, Data)),
    Reply = json{status:"ok",operation:Operation,data:Data}.

kb_decide("analyze", Args, Data) :-
    !,
    require_id(Args, id, Id),
    star_reasoning:tool_packet(Id, 24, Packet),
    term_as_text(Packet, Evidence),
    findnsols(24, Conflict,
              star_reasoning:tool_contradictions(Id, Conflict), Conflicts),
    maplist(term_as_text, Conflicts, ConflictTexts),
    ( Conflicts == [] -> Next = "inspect_sources_and_missing_evidence"
    ; Next = "review_contested_claims" ),
    Data = json{entity:Args.id,source:"star-kb",reasoning:Evidence,
                contradictions:ConflictTexts,recommendedAction:Next,
                knowledgeStatus:"inferred_not_canonical"}.
kb_decide(Op, Args, Data) :-
    kb_goal(Op, Args, Goal, Result),
    findnsols(32, Result, Goal, Terms),
    maplist(term_as_text, Terms, Answers),
    length(Terms, Count),
    Data = json{source:"star-kb",results:Answers,count:Count,
                truncatedAt:32,knowledgeStatus:"inferred_not_canonical"}.

kb_goal("document", Args, star_reasoning:tool_document(Id, Result), Result) :-
    require_id(Args, id, Id).
kb_goal("neighbors", Args, star_reasoning:tool_neighbors(Id, Direction, Result), Result) :-
    require_id(Args, id, Id),
    ( get_dict(direction, Args, D0) -> string_atom(D0, Direction) ; Direction=both ),
    memberchk(Direction, [in,out,both]).
kb_goal("path", Args, star_reasoning:tool_path(A,B,Depth,Result), Result) :-
    require_id(Args, source, A), require_id(Args, target, B),
    ( get_dict(max_depth, Args, Depth) -> true ; Depth=4 ),
    integer(Depth), between(1,12,Depth).
kb_goal("explain", Args, star_reasoning:tool_explain_relation(Id,Result), Result) :-
    require_id(Args, relation_id, Id).
kb_goal("timeline", Args, star_reasoning:tool_timeline(Id,Result), Result) :-
    require_id(Args, id, Id).
kb_goal("contradictions", Args, star_reasoning:tool_contradictions(Id,Result), Result) :-
    require_id(Args, id, Id).
kb_goal("compare", Args, star_reasoning:tool_compare(A,B,Result), Result) :-
    require_id(Args, left, A), require_id(Args, right, B).
kb_goal("sources", Args, star_reasoning:tool_sources(Id,Result), Result) :-
    require_id(Args, id, Id).
kb_goal("why-not", Args, star_reasoning:tool_why_not(S,P,O,Result), Result) :-
    require_id(Args, subject, S), require_id(Args, predicate, P),
    require_id(Args, object, O).
kb_goal("referrers", Args, star_reasoning:tool_referrers(Id,Result), Result) :-
    require_id(Args, target, Id).
kb_goal("values", Args, star_reasoning:tool_values(Id,Prefix,Result), Result) :-
    require_id(Args, id, Id), require_id(Args, path_prefix, Prefix).
kb_goal("packet", Args, star_reasoning:tool_packet(Id,24,Result), Result) :-
    require_id(Args, id, Id).
kb_goal("route", Args, star_reasoning:tool_route_reasoning(Task,U,R,E,B,Result), Result) :-
    require_id(Args, task, Task),
    flag(Args, uncertainty, U), flag(Args, recursion, R),
    flag(Args, explanation, E), flag(Args, bulk, B).
kb_goal(Operation, _, _, _) :-
    throw(error(domain_error(star_kb_operation,Operation), _)).

flag(Dict, Field, Flag) :-
    ( get_dict(Field, Dict, Flag0) -> memberchk(Flag0,[true,false]), Flag=Flag0
    ; Flag=false ).

require_id(Dict, Key, Value) :-
    ( get_dict(Key, Dict, Text),
      string(Text), string_length(Text, N), between(1,1024,N)
    -> atom_string(Value,Text)
    ; throw(error(domain_error(star_kb_argument,Key), _)) ).

string_atom(S, Atom) :-
    string(S), atom_string(Atom,S).

term_as_text(Term, Text) :-
    term_string(Term, Raw, [quoted(true),max_depth(12),numbervars(true)]),
    string_length(Raw, N),
    ( N > 8000 -> sub_string(Raw,0,8000,_,Text) ; Text=Raw ).

kb_error(star_kb_not_configured, json{status:"error",code:"star_kb_not_configured",
         message:"Set STAR_KB_ROOT and STAR_KB_PROJECTION to the real Star-KB repository and trusted generated projection"}) :- !.
kb_error(star_kb_files_missing, json{status:"error",code:"star_kb_files_missing",
         message:"Star-KB exported reasoning module or trusted projection is absent"}) :- !.
kb_error(error(star_kb_not_configured,_), Reply) :-
    !, kb_error(star_kb_not_configured, Reply).
kb_error(error(star_kb_files_missing,_), Reply) :-
    !, kb_error(star_kb_files_missing, Reply).
kb_error(time_limit_exceeded, json{status:"error",code:"query_timeout",
         message:"Symbolic query exceeded the four-second budget"}) :- !.
kb_error(_, json{status:"error",code:"kb_query_failed",
         message:"Star-KB rejected this bounded symbolic query"}).
