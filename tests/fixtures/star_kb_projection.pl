% Synthetic StarIntel projection for Star-KB compatibility checks.
% This is trusted generated-style test data, not executable end-user input.
star_doc('starintel:device:radio-1', 'device', 'fixture', '0.10.1', 1, '').
star_profile('starintel:device:radio-1','starintel-core','0.10.1','fixture','0.10.1').
star_doc('starintel:relation:broadcast', 'relation', 'fixture', '0.10.1', 1, '').
star_profile('starintel:relation:broadcast','starintel-core','0.10.1','fixture','0.10.1').
star_relation('starintel:relation:broadcast',
              'starintel:device:radio-1','broadcasts-ssid',
              'starintel:ssid:guest',true,false,0.9,'','').
star_source('starintel:relation:broadcast',
            'starintel:source:synthetic','fixture',
            'https://example.invalid/fixture',0.7,0.8,'sha256:fixture').
star_evidence('starintel:relation:broadcast',
              'starintel:evidence:demo',
              'starintel:source:synthetic','supports',
              'synthetic observation',0.9,'unverified').
