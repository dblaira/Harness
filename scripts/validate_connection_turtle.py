#!/usr/bin/env python3
"""Validate understood:Connection Turtle with SHACL."""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path

from pyshacl import validate
from rdflib import Graph, Namespace
from rdflib.namespace import RDF, SH

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SHAPES = ROOT / "Ontology/shapes/connection-shape.ttl"

UNDERSTOOD = Namespace("https://understood.app/ontology#")


def read_data(path: str | None) -> str:
    if path:
        return Path(path).read_text()
    return sys.stdin.read()


def message_for_result(report: Graph, result) -> str:
    path = report.value(result, SH.resultPath)
    component = report.value(result, SH.sourceConstraintComponent)
    messages = [str(msg) for msg in report.objects(result, SH.resultMessage)]
    message_text = " ".join(messages).lower()

    if path == UNDERSTOOD.label:
        return "missing label"
    if path == UNDERSTOOD.strength:
        return "strength must be a number from 0 to 1"
    if path == UNDERSTOOD.inLifeDomain:
        if "mincount" in str(component).lower():
            return "missing life domain"
        return "unknown life domain; use one of the 13 approved domains"
    if path == UNDERSTOOD.acceptedAt:
        return "accepted date is malformed"
    if path == UNDERSTOOD.frequency:
        return "frequency must be usually or sometimes"
    if path == UNDERSTOOD.connectionType:
        return "missing connection type"
    if path == UNDERSTOOD.evidenceNote:
        return "evidence note must be text"
    if message_text:
        return messages[0]
    return "claim does not match the accepted connection grammar"


def plain_messages(report_graph) -> list[str]:
    report = Graph()
    report.parse(data=report_graph.serialize(format="turtle"), format="turtle")
    results = list(report.subjects(RDF.type, SH.ValidationResult))
    messages: list[str] = []
    for result in results:
        message = message_for_result(report, result)
        if message not in messages:
            messages.append(message)
    return messages or ["claim does not match the accepted connection grammar"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("ttl", nargs="?")
    parser.add_argument("--shapes", type=Path, default=DEFAULT_SHAPES)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    data = read_data(args.ttl)
    with tempfile.NamedTemporaryFile("w", suffix=".ttl", delete=False) as handle:
        handle.write(data)
        data_path = Path(handle.name)

    try:
        conforms, report_graph, report_text = validate(
            data_graph=str(data_path),
            shacl_graph=str(args.shapes),
            data_graph_format="turtle",
            shacl_graph_format="turtle",
            inference="rdfs",
            abort_on_first=False,
            allow_infos=False,
            allow_warnings=False,
        )
    except Exception as exc:
        payload = {
            "conforms": False,
            "messages": ["Turtle could not be parsed or validated."],
            "raw": str(exc),
        }
        if args.json:
            print(json.dumps(payload, indent=2, sort_keys=True))
        else:
            print("Blocked: Turtle could not be parsed or validated.")
        return 1
    finally:
        try:
            data_path.unlink()
        except OSError:
            pass

    payload = {
        "conforms": bool(conforms),
        "messages": [] if conforms else plain_messages(report_graph),
        "raw": report_text,
    }
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    elif conforms:
        print("valid")
    else:
        print("Blocked: " + "; ".join(payload["messages"]))
    return 0 if conforms else 1


if __name__ == "__main__":
    raise SystemExit(main())
