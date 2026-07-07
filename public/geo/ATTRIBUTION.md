Reference dataset for placing labeled pins on the Results "Compare regions"
map when a respondent-tagged location can be resolved by name. Used purely
for rendering (name → approximate lat/lng); nothing here is respondent
data, and nothing from a Response record is written back into it.

`region_coords.json` merges two sources:

- States/provinces (admin-1 regions, ~5,300 entries): [Countries States
  Cities Database](https://github.com/dr5hn/countries-states-cities-database),
  © contributors, [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/)
  (attribution + share-alike required).
- Cities (~170,000 entries, population > 1000): [cities.json](https://github.com/lutangar/cities.json),
  sourced from the [GeoNames Gazetteer](https://www.geonames.org/),
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) (attribution
  required).

On a name collision within a country, the state/province entry wins over
a city of the same name (built by `region_coords.json`'s generation
script — see `results_compare_controller.js` for the consuming code).

Per-country geographic bounds (used to place a pin proportionally within
the map's own drawn shape) are the 2nd/98th percentile of each source's
raw lat/lng per country, not the strict min/max — a handful of mislabeled
or overseas-territory entries in the raw data otherwise blow a country's
bounding box out by tens of degrees.
