# Calculator

Type a calculation in the root search. The answer is the first row: the query as understood on the left, the answer on the right. Other readings of an ambiguous query (US or imperial gallon, `5 % 3` as modulo or percent) follow as rows.

| Key | Action |
|---|---|
| ↵ | Copy the answer as shown (`112 278,90 USD`) |
| ⌘↵ | Copy the number alone, no grouping, for spreadsheets (`112278.9028`) |
| ⌘I | Show the steps of a chain: each operation with its running result |
| ⌘K | Copy, Copy Number, Paste, Show Steps |

The last answer you copied or pasted is `ans` in the next query.

## What it understands

| Kind | Examples |
|---|---|
| Arithmetic | `2^3^2`, `25!`, `sqrt 2`, `8/2(2+2)`, `10 choose 3`, `round(3.14159, 2)` |
| Percentages | `200 + 10%`, `15% tip on 80`, `20 is what % of 200`, `1250 kr uten mva` |
| Units | `6 ft 2 in in cm`, `180 cm in feet and inches`, `100 km/h in m/s`, `8 l/100km in mpg` |
| Chains | `12 days minus 30 minutes in seconds`, `500 km at 6 l/100km at 21 kr/l in eur`, `3 GB at 10 MB/s` |
| Currency | `100 usd in nok`, `$200 + €200`, `1000 sats in usd`, `100 nok in usd at 10.5` |
| Time | `5pm PST in Oslo`, `time in Tokyo`, `9:30 to 17:15`, `days until christmas`, `31 jan 2027 + 1 month` |
| Data | `1 TB in GiB`, `100 Mbps in MB/s`, `1 TB at 50 Mbps` |
| Temperature | `350 F in C`, `20 C + 5 F`, `20 C - 15 C in F` (a 9 °F difference) |
| Programmer | `255 in hex`, `0xFF & 0x0F`, `1 << 64`, `rgb(255, 136, 0) to hex` |
| Words | `half of 80`, `two thirds of 90`, `how many feet in a mile`, `fifty-five plus one hundred and twenty` |
| Norwegian | `100 kr i dollar`, `3 timer og 20 min i sekunder`, `dager til 17. mai`, `5 mrd / 5,5 mill` |

Plain numbers, bare quantities (`10 km`) and names with digits (`iPhone 15`, `1Password`, `mp3`) never show a row. A calculation without an answer shows why: `5 km + 3 kg` → "Can't add a length (km) and a mass (kg)".

A chain worth trying, a four-person road trip Oslo–Lofoten and back, split per person:

```
(2 × 1450 km at 6.8 l/100km at 21.40 kr/l + 2 × 1450 km at 0.45 kr/km + 6 days at 1290 kr/day + 2 at 890 kr) / 4 in eur
```

⌘I lists 2900 km → 197,2 L of fuel → 4220,08 NOK → plus tolls, cabins and ferries → 15 045,08 NOK → 3761,27 NOK each → 350,93 EUR.

## Conventions

- Numbers are exact: `0.1 + 0.2` is `0.3`, `2^64` is every digit. Results show 10 significant digits.
- A year as a duration is 365 days and a month 365/12 days; dates move by calendar months (`31 jan + 1 month` = 28 Feb).
- `kr` is NOK, `mil` is 10 km for Norwegian speakers, `cup`, `gallon` and `tbsp` are US with the other systems offered.
- `m` is metres, or minutes when only that makes sense (`5 m + 30 s`); `K` after a number is a thousand unless a temperature is asked for.

## Exchange rates

Fiat rates come from Norges Bank's daily fixing, crypto from CoinGecko, refreshed at most every six hours while the launcher is used and cached in the support directory. Without a network the last rates keep working.

## Tests

`docs/calculator-fixtures.json` holds 618 queries with expected answers. `swift test --filter FixtureTests` runs them and writes a report (`CALC_REPORT` sets its path); `CALC_Q="query" swift test --filter FixtureTests/query` shows how one query is read. `just calc "query"` prints the answer from the command line.
