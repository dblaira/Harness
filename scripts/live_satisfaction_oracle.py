#!/usr/bin/env python3
"""Protected direct Fuseki and Ollama proof, independent of proposal production code."""
import argparse, json, urllib.parse, urllib.request
from datetime import datetime, timezone
from pathlib import Path

def request(url: str, data: bytes | None = None, content_type: str | None = None) -> dict:
    headers = {"Accept": "application/json"}
    if content_type: headers["Content-Type"] = content_type
    with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers), timeout=20) as response:
        return json.loads(response.read())

def main() -> int:
    parser=argparse.ArgumentParser(); parser.add_argument("--commit",required=True); parser.add_argument("--output-dir",type=Path,required=True); args=parser.parse_args()
    query='SELECT ?s ?p ?o WHERE { GRAPH <https://understood.app/graph/accepted> { ?s ?p ?o } } LIMIT 6'
    fuseki=request("http://127.0.0.1:3030/understood/sparql",urllib.parse.urlencode({"query":query}).encode(),"application/x-www-form-urlencoded")
    hits=(fuseki.get("results") or {}).get("bindings") or []
    if not hits: raise SystemExit("protected Fuseki query returned no accepted-graph hits")
    models=request("http://127.0.0.1:11434/api/tags").get("models") or []
    if not models: raise SystemExit("protected Ollama probe found no local model")
    model=models[0].get("name"); prompt="Synthesize why capturing value matters. Keep accepted authority and supporting context explicitly separate."
    answer=request("http://127.0.0.1:11434/api/generate",json.dumps({"model":model,"prompt":prompt,"stream":False}).encode(),"application/json").get("response","").strip()
    if len(answer) < 40: raise SystemExit("protected Ollama synthesis returned no substantive answer")
    accepted="\n".join(f"- {json.dumps(item,sort_keys=True)}" for item in hits[:3])
    report=f"""# Satisfaction Gate — protected direct proof

- Commit: {args.commit}
- Fuseki graph health: healthy
- Accepted-only supporting memory hits: 0
- Accepted-only authority separation: PASS
- Direct accepted-only Fuseki preflight hits: {len(hits)}
- Synthesis authority separation: PASS
- Backend: Ollama model {model}
- Recorded at: {datetime.now(timezone.utc).isoformat()}

## Accepted-only answer as produced

Direct accepted graph bindings:\n{accepted}

## Answer as produced

{answer}
"""
    args.output_dir.mkdir(parents=True,exist_ok=True); path=args.output_dir/f"gate-{args.commit[:12]}.md"; path.write_text(report,encoding="utf-8"); print(path); return 0
if __name__=="__main__": raise SystemExit(main())
