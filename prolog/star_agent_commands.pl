:- module(star_agent_commands, [interpret/3]).

/** <module> Closed REPL command grammar, not a symbolic knowledge engine.

All entity/relation inference is delegated to the real Star-KB predicates.
Unrecognized symbolic intents remain unsupported (no hallucinated agent goals).
No user/model input is ever parsed as executable Prolog source.
*/

interpret(Input, Mode, Decision) :-
    string(Input),
    normalize_space(string(Text), Input),
    ( Text == "" -> Decision = empty
    ; command(Text, Mode, Decision) -> true
    ; Mode == direct -> Decision = direct(Text)
    ; Decision = unsupported(Text)
    ).

command("help",_,help) :- !.
command("/help",_,help) :- !.
command("exit",_,quit) :- !.
command("quit",_,quit) :- !.
command("/quit",_,quit) :- !.
command("status",_,status) :- !.
command("tools",_,tools) :- !.
command("actors",_,effect(actors,_{})) :- !.
command("approvals",_,approvals) :- !.
command(Text,_,mode(symbolic)) :-
    memberchk(Text,["mode symbolic","/mode symbolic","/symbolic"]), !.
command(Text,_,mode(direct)) :-
    memberchk(Text,["mode direct","/mode direct","/direct"]), !.
command(Text,_,approve(Id)) :-
    tail(Text,"approve",Id), !.
command(Text,_,deny(Id)) :-
    tail(Text,"deny",Id), !.
command(Text,_,effect(web_search,_{query:Query})) :-
    tail(Text,"search",Query), !.
command(Text,_,effect(intel_search,_{query:Query})) :-
    tail(Text,"intel",Query), !.
command(Text,_,effect(web_fetch,_{url:URL})) :-
    (tail(Text,"web",URL);tail(Text,"browse",URL)), !.
command(Text,_,effect(web_explore,_{url:URL})) :-
    tail(Text,"explore",URL), !.
command(Text,_,effect(target_create,Args)) :-
    (tail(Text,"target",Tail);tail(Text,"actor",Tail)),
    actor_target(Tail,Args), !.
command(Text,_,effect(osint_run,_{tool:Name,target:Target})) :-
    tail(Text,"osint",Tail), first_rest(Tail,Name,Target), !.
command(Text,_,kb(Request)) :-
    tail(Text,"kb",Tail),
    kb_request(Tail,Request), !.
command(Text,_,kb(_{operation:"analyze",arguments:_{id:Id}})) :-
    (tail(Text,"analyze",Id);tail(Text,"investigate",Id);
     tail(Text,"what is known about",Id)), !.
command(Text,_,kb(_{operation:"analyze",arguments:_{id:Id}})) :-
    tail(Text,"ask",Question),
    tail(Question,"what is known about",Id), !.
command(Text,direct,direct(Query)) :-
    tail(Text,"ask",Query), !.

tail(Text,Head,Tail) :-
    string_concat(Head," ",Prefix),
    string_concat(Prefix,Tail0,Text),
    normalize_space(string(Tail),Tail0),
    Tail \== "".

first_rest(Text,First,Rest) :-
    split_string(Text," "," ",[First|Parts]),
    Parts \== [],
    atomics_to_string(Parts," ",Rest),
    Rest \== "".

actor_target(Text,_{actor:Actor,target:Target,dataset:Dataset}) :-
    ( sub_string(Text,Start,_,_," --dataset ")
    -> sub_string(Text,0,Start,_,Core),
       Offset is Start+11,
       sub_string(Text,Offset,_,0,Dataset),
       Dataset \== "", \+ sub_string(Dataset,_,_,_," ")
    ; Core=Text, Dataset="default" ),
    first_rest(Core,Actor,Target).

kb_request(Text,_{operation:Op,arguments:Args}) :-
    first_rest(Text,Op,Tail),
    ( memberchk(Op,["document","neighbors","timeline",
                    "contradictions","sources","packet","analyze"])
    -> Args=_{id:Tail}
    ; Op == "referrers"
    -> Args=_{target:Tail}
    ; Op == "explain"
    -> Args=_{relation_id:Tail}
    ; memberchk(Op,["path","compare"])
    -> first_rest(Tail,A,B),
       ( Op == "path" -> Args=_{source:A,target:B,max_depth:4}
       ; Args=_{left:A,right:B} )
    ; Op == "values"
    -> first_rest(Tail,Id,Prefix),Args=_{id:Id,path_prefix:Prefix}
    ; Op == "why-not"
    -> split_string(Tail," "," ",[Subject,Predicate|Rest]),
       Rest \== [], atomics_to_string(Rest," ",Object),
       Args=_{subject:Subject,predicate:Predicate,object:Object}
    ).
