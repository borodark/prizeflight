## Phase 1: System Design

Design a high-level service architecture for a flight price tracker that ingests real-time price updates and allows users to track trips (origin and destination).

## Phase 2: Elixir Implementation

Implement a Phoenix endpoint to ingest and persist the real-time flight price update events into a database.

```json
{
  "event_id": "d0032287-9d1b-4767-a24b-20d21ede638f",
  "route_id": "LAX-JFK-2025-10-26",
  "origin_airport_code": "LAX",
  "destination_airport_code": "JFK",
  "departure_date": "2025-10-26T15:00:00Z",
  "price": 350.75,
  "currency": "USD",
  "timestamp": "2025-07-07T15:00:00Z",
  "airline_code": "AA"
}
```
