{
  description = "Star-Agent symbolic REPL using producer-owned Star-KB and prolog-rlm";
  inputs = {
    star-kb.url = "github:starintel-labs/star-kb/c13a99bdaf579fc7c0a8e83376a3e3f88132e8e1";
    prolog-rlm.url = "github:lost-rob0t/prolog-rlm/2596e3f7155a543026adde461a11326c60e1a756";
    nixpkgs.follows = "star-kb/nixpkgs";
  };
  outputs = { self, nixpkgs, star-kb, prolog-rlm }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      kb = star-kb.packages.${system}.prolog-star-kb;
      rlm = prolog-rlm.packages.${system}.prolog-rlm;
      kbRoot = "${kb}/share/star-kb";
      rlmRoot = "${rlm}/share/swi-prolog/pack/prolog_rlm";
      runtime = [ pkgs.python3 pkgs.swi-prolog pkgs.dnsutils pkgs.whois pkgs.subfinder ];
      agent = pkgs.stdenvNoCC.mkDerivation {
        pname = "star-agent";
        version = "0.1.0";
        src = self;
        nativeBuildInputs = [ pkgs.makeWrapper ] ++ runtime;
        dontBuild = true;
        doCheck = true;
        checkPhase = ''
          export STAR_KB_ROOT=${kbRoot}
          export PROLOG_RLM_ROOT=${rlmRoot}
          export STAR_KB_PROJECTION="$PWD/tests/fixtures/star_kb_projection.pl"
          python3 -m py_compile scripts/*.py
          python3 -m unittest discover -s tests -p 'test_*.py' -v
          swipl -q -s tests/star_agent_plunit.pl -g 'run_tests,halt(0)' -t 'halt(1)'
          swipl -q -s tests/star_kb_integration.pl -g 'run_tests,halt(0)' -t 'halt(1)'
          swipl -q -s tests/star_rlm_integration.pl -g 'run_tests,halt(0)' -t 'halt(1)'
          python3 scripts/sync.py
          python3 scripts/sync.py --check
          python3 scripts/validate-docs.py
        '';
        installPhase = ''
          mkdir -p "$out/share/star-agent" "$out/bin"
          cp -R prolog star_agent "$out/share/star-agent/"
          makeWrapper ${pkgs.swi-prolog}/bin/swipl "$out/bin/star-agent" \
            --add-flags "-q -s $out/share/star-agent/prolog/star_agent_repl.pl --" \
            --prefix PYTHONPATH : "$out/share/star-agent" \
            --prefix PATH : ${pkgs.lib.makeBinPath runtime} \
            --set STAR_KB_ROOT ${kbRoot} \
            --set PROLOG_RLM_ROOT ${rlmRoot} \
            --set-default SSL_CERT_FILE ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
        '';
        doInstallCheck = true;
        installCheckPhase = ''
          sourceRoot="$PWD"
          mkdir -p "$TMPDIR/installed-agent"
          cd "$TMPDIR/installed-agent"
          unset PYTHONPATH STAR_KB_ROOT PROLOG_RLM_ROOT
          "$out/bin/star-agent" --command help
          "$out/bin/star-agent" --command status | python3 -c \
            'import json,sys; d=json.load(sys.stdin); assert d["mode"] == "symbolic" and d["symbolicEngine"] == "star-kb"'
          "$out/bin/star-agent" --command kb neighbors starintel:device:radio-1 | python3 -c \
            'import json,sys; d=json.load(sys.stdin); assert d["status"] == "ok" and d["data"]["count"] >= 1'
          printf 'status\nquit\n' | "$out/bin/star-agent" > repl.txt
          grep -F 'Star-KB symbolic REPL' repl.txt
          cd "$sourceRoot"
        '';
        meta = { mainProgram = "star-agent"; platforms = [ system ]; };
      };
    in {
      packages.${system} = { default = agent; star-agent = agent; };
      apps.${system} = {
        default = self.apps.${system}.star-agent;
        star-agent = { type = "app"; program = "${agent}/bin/star-agent"; };
      };
      checks.${system}.default = agent;
      devShells.${system}.default = pkgs.mkShell {
        packages = runtime;
        STAR_KB_ROOT = kbRoot;
        PROLOG_RLM_ROOT = rlmRoot;
      };
    };
}
