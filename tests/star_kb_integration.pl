:- begin_tests(star_kb_integration).

:- use_module('../prolog/star_agent_kb').

test(real_star_kb_neighbors, [condition(getenv('STAR_KB_ROOT',_))]) :-
    kb_query(_{operation:"neighbors",
               arguments:_{id:"starintel:device:radio-1"}},Reply),
    assertion(Reply.status == "ok"),
    assertion(Reply.data.count >= 1),
    atomics_to_string(Reply.data.results, " ", Text),
    sub_string(Text,_,_,_,"broadcasts-ssid").

test(real_star_kb_relation_explanation, [condition(getenv('STAR_KB_ROOT',_))]) :-
    kb_query(_{operation:"explain",
               arguments:_{relation_id:"starintel:relation:broadcast"}},Reply),
    assertion(Reply.status == "ok"),
    assertion(Reply.data.count == 1),
    atomics_to_string(Reply.data.results, " ", Text),
    sub_string(Text,_,_,_,"starintel:source:synthetic").

test(real_star_kb_analyze_only_infers, [condition(getenv('STAR_KB_ROOT',_))]) :-
    kb_query(_{operation:"analyze",
               arguments:_{id:"starintel:device:radio-1"}},Reply),
    assertion(Reply.status == "ok"),
    assertion(Reply.data.knowledgeStatus == "inferred_not_canonical").

test(deny_arbitrary_kb_goals, [condition(getenv('STAR_KB_ROOT',_))]) :-
    kb_query(_{operation:"call",arguments:_{id:"test"}},Reply),
    assertion(Reply.status == "error").

:- end_tests(star_kb_integration).
