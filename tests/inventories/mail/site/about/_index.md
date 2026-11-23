+++
title = "Om oss"
description = "Vi som driftar."

[extra]
inquiry = """
Vi behöver hjälp med …
"""
+++

Alice hjälper till.

{{ <skills items={["NixOS", "WireGuard"]} /> }}

{% <experience title="Erfarenhet" skills={["WireGuard"]}> %}

Föreningens [e-post](@/policy/_index.md).

{% </experience> %}

{% <disclaimer title="Just nu"> %}

Alice är på semester.

{% </disclaimer> %}

{{ <points items={[["unplug", "accent", "Förbli oberoende", "Det vi bygger går att sköta utan oss."]]} /> }}

{% <sandbox test={["Testmiljö", "Misstag stannar här."]} ai="AI" data="Testdata"
  review={["Granskning", "Alice läser koden."]} live={["Era system", "Riktiga data."]}> %}

Inget når era system ogranskat.

{% </sandbox> %}

{% <foundation label="Uppdrag" items={[["workflow", "Automatisera"]]} base={["server", "Drift"]}> %}

Servrar och backup.

{% </foundation> %}

## Automatisera

Det som görs för hand.

## Drift

Det allt vilar på.
