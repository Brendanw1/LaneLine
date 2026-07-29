# Third-party data and services

The MIT license in `LICENSE` covers the LaneLine source code. It does **not**
cover the bundled datasets in `Resources/`, which come from third parties
under their own terms:

## OpenStreetMap (`Resources/SFStreetNetwork.json`)

Derived from an OpenStreetMap extract via [BBBike.org](https://download.bbbike.org/osm/bbbike/),
filtered to rideable ways (excludes motorways, steps, construction, and
`bicycle=no`/`private`), with tags reduced to what routing needs.

© OpenStreetMap contributors, available under the
[Open Database License (ODbL) v1.0](https://opendatacommons.org/licenses/odbl/1-0/).
Bundling this extract in the repository is a redistribution of an ODbL
database, not just a "produced work" — if you fork or redistribute this
project, you take on the same ODbL attribution obligation for that file.

## SFMTA bikeway data (`Resources/MTA_Bike_Network_Linear_Features.csv`, `Resources/Protected_Bike_Lanes.csv`)

San Francisco Municipal Transportation Agency, via [DataSF](https://datasf.org/opendata/)
open data ([`ygmz-vaxd`](https://data.sfgov.org/resource/ygmz-vaxd.json) and
related datasets). Published for public reuse.

## Bike parking (`Resources/SFBikeParkingRacks.csv`)

SFMTA, via DataSF, same terms as above.

## Elevation

Fetched live (and disk-cached) from:
- [Open-Meteo](https://open-meteo.com/) — Copernicus GLO-90 DEM, CC BY 4.0.
- [USGS 3DEP Elevation Point Query Service](https://apps.nationalmap.gov/epqs/) — U.S. public domain.

Bundled in `Resources/SFBikewayElevations.json` for the local bikeway network
only.

## Lyrics

Fetched live, not bundled, from [LRCLIB](https://lrclib.net/) — a free,
keyless, community-sourced lyrics database. Not affiliated with or licensed
by rights holders; coverage and accuracy vary by track, and lyrics text
itself remains the copyright of the original songwriters/publishers.
