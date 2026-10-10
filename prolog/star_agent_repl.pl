:- module(star_agent_repl,
          [ main/1,
            run_command/3,
            execute_line/3
          ]).

/** <module> Star-KB symbolic REPL with opt-in prolog-rlm direct mode. */

:- use_module(library(http/json)).
:- use_module(library(readutil)).
:- use_module(star_agent_catalog).
:- use_module(star_agent_commands).
:- use_module(star_agent_kb).
:- use_module(star_agent_effect).
:- use_module(star_agent_direct).

:- dynamic current_mode/1.
:- initialization(main,main).

initialize :-
    (current_mode(_)->true;assertz(current_mode(symbolic))).

set_mode(Mode) :-
    memberchk(Mode,[symbolic,direct]),
    retractall(current_mode(_)),
    assertz(current_mode(Mode)).

main(Argv) :-
    initialize,
    setup_call_cleanup(true,command_main(Argv,Exit),
                       star_agent_direct:shutdown),
    halt(Exit).

command_main([],0) :- !,
    format('Star-Agent | Star-KB symbolic REPL (no LLM by default)~n'),
    loop.
command_main(['--mode',Mode|Rest],Code) :-
    !,
    (memberchk(Mode,[symbolic,direct])
    -> set_mode(Mode),command_main(Rest,Code)
    ; Code=2,format(user_error,'unknown mode~n',[])).
command_main(['--command'|Args],Code) :-
    Args\==[], !,
    atomics_to_string(Args,' ',Input),
    current_mode(Mode),
    run_command(Input,Mode,Reply),
    write_reply(Reply),
    (Reply.status == "error" -> Code=1 ; Code=0).
command_main(['--help'],0) :-
    !,execute_line("help",symbolic,Reply),write_reply(Reply).
command_main(_,2) :-
    format(user_error,'Usage: bin/star-agent [--mode symbolic|direct] [--command WORDS...]~n',[]).

loop :-
    repeat,
    current_mode(Mode),
    format('star(~w)> ',[Mode]),flush_output,
    read_line_to_string(user_input,Input),
    ( Input == end_of_file -> !
    ; run_command(Input,Mode,Reply), write_reply(Reply),
      (Reply.status == "quit" -> ! ; fail) ).

run_command(Input,Mode,Reply) :-
    catch(execute_line(Input,Mode,Reply),
          _, Reply=json{status:"error",code:"command_failed",
                         message:"The requested command could not complete"}).

execute_line(Input,Mode,Reply) :-
    star_agent_commands:interpret(Input,Mode,Decision),
    execute_decision(Decision,Mode,Reply).

execute_decision(empty,_,json{status:"ok",message:""}).
execute_decision(quit,_,json{status:"quit"}).
execute_decision(help,_,json{status:"ok",commands:[
    "mode symbolic","mode direct","status","tools","actors",
    "search TERMS","intel TERMS","web URL","explore URL",
    "kb packet ID","kb neighbors ID","kb path ID1 ID2",
    "kb explain RELATION-ID","kb contradictions ID",
    "kb why-not SUBJECT PREDICATE OBJECT","analyze ID",
    "target ACTOR TARGET [--dataset DATASET]",
    "osint dns|whois|subfinder DOMAIN",
    "ask QUESTION (direct mode)", "approvals",
    "approve APPROVAL-ID","deny APPROVAL-ID","quit"
]}).
execute_decision(mode(New),_,json{status:"ok",mode:Name}) :-
    set_mode(New),atom_string(New,Name).
execute_decision(status,Mode,json{status:"ok",mode:Name,
                                symbolicEngine:"star-kb",
                                starKBConfigured:KB,
                                prologRLMConfigured:RLM,
                                serverConfigured:Server,
                                searchConfigured:Search}) :-
    atom_string(Mode,Name),
    star_agent_kb:kb_ready(KB),
    (getenv('PROLOG_RLM_ROOT',_)->RLM=true;RLM=false),
    (getenv('STAR_AGENT_SERVER_URL',_)->Server=true;Server=false),
    (getenv('STAR_AGENT_SEARXNG_URL',_)->Search=true;Search=false).
execute_decision(tools,_,json{status:"ok",tools:List}) :-
    findall(json{name:Name,effect:Effect,description:Description},
       (tool_spec(Tool,Type,Description,_),
        atom_string(Tool,Name),atom_string(Type,Effect)),List).
execute_decision(effect(Name,Args),_,Reply) :-
    star_agent_effect:effect_call(Name,Args,Reply).
execute_decision(kb(Request),_,Reply) :-
    star_agent_kb:kb_query(Request,Reply).
execute_decision(direct(Prompt),direct,Reply) :-
    star_agent_direct:direct_turn(Prompt,Reply).
execute_decision(direct(_),symbolic,
                 json{status:"error",code:"symbolic_only",
                      message:"Only named Star-KB queries and supported commands run without LLMs"}).
execute_decision(approvals,_,Reply) :-
    star_agent_direct:approvals(Reply).
execute_decision(approve(Id),_,Reply) :-
    star_agent_direct:approve(Id,Reply).
execute_decision(deny(Id),_,Reply) :-
    star_agent_direct:deny(Id,Reply).
execute_decision(unsupported(_),symbolic,
                 json{status:"error",code:"unsupported_symbolic_intent",
                      message:"Star-KB cannot interpret this intent; use a named KB/tool command or switch to direct mode"}).

write_reply(Reply) :-
    json_write_dict(current_output,Reply),nl,flush_output.
