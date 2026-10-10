:- module(star_agent_effect, [effect_call/3]).

/** <module> Bounded effect bridge to the installed Python adapters.

Input is JSON, not a command or Prolog goal. Never interpolate user input into
a shell command. Python may execute only named allowlisted provider operations.
*/

:- use_module(library(http/json)).
:- use_module(library(process)).
:- use_module(library(readutil)).
:- use_module(library(time)).
:- use_module(star_agent_catalog).

effect_call(Name, Args, Reply) :-
    ( public_tool(Name), Name \== kb_query,
      is_dict(Args), ground(Args)
    -> effect_call_checked(Name, Args, Reply)
    ; Reply = json{status:"error",code:"invalid_effect_request"} ).

effect_call_checked(Name, Args, Reply) :-
    atom_string(Name, Word),
    catch(setup_call_cleanup(
      process_create(path(python3),
                     ['-m','star_agent.effects',Word],
                     [stdin(pipe(In)),stdout(pipe(Out)),stderr(null),process(Pid)]),
      call_with_time_limit(55,
           exchange(Pid, In, Out, Args, Reply)),
      cleanup(Pid, In, Out)),
      _, Reply = json{status:"error",code:"effect_bridge_failure"}).

exchange(Pid, In, Out, Args, Reply) :-
    json_write_dict(In, Args), nl(In), flush_output(In), close(In),
    read_string(Out, 32769, Output),
    ( string_length(Output, Length), Length =< 32768,
      catch(atom_json_dict(Output, Payload, []), _, fail),
      is_dict(Payload)
    -> Reply = Payload
    ; Reply = json{status:"error",code:"invalid_effect_reply"} ),
    process_wait(Pid, _).

cleanup(Pid, In, Out) :-
    catch(close(In),_,true),
    catch(close(Out),_,true),
    catch(process_kill(Pid,term),_,true),
    catch(process_wait(Pid,_,[timeout(0.1)]),_,true).
