/* Clean up the block group data with human friendly names and int datatypes. Also creates a geoid join key.*/
DROP VIEW IF EXISTS block_group_clean;
CREATE VIEW block_group_clean AS
SELECT 
    ("state" || county || tract || block_group)::TEXT AS geoid, --Build the GEOID join key
    b01003_001e::INTEGER AS pop_total, -- data imported as float from numpy, but better to store as int.
    b25044_001e::INTEGER AS households_total,
    b19013_001e AS median_income,-- leaving this as a float type.
    b19313_001e AS income_total, -- leaving this as a float type.
    (b25044_003e + b25044_010e)::INTEGER AS hh_no_car_total,
    b15003_001e::INTEGER AS pop_25_plus_total,
    (b15003_022e + b15003_023e + b15003_024e + b15003_025e)::INTEGER AS bachelors_plus_total, -- sums relavent education categeories to find total with bachelors or higher
    b08301_001e::INTEGER AS workers_16_plus_total,
    b08301_003e::INTEGER AS drove_alone_total,
    b08301_004e::INTEGER AS carpooled_total,
    b08301_010e::INTEGER AS took_transit_total,
    b08301_021e::INTEGER AS worked_from_home_total
FROM acs5_bg_2024;

/* Clean up the block data from both the census and LODES datasets with human friendly names and int datatypes. Also creates a geoid join key. */
DROP VIEW IF EXISTS block_clean;
CREATE VIEW block_clean AS
WITH block_join AS (
    SELECT 
        ("state" || county || tract || "block")::TEXT AS geoid, -- Build the GEOID join key
        p2_001n::INTEGER AS pop_total,
        p2_005n::INTEGER AS pop_white_alone_total
    FROM census_block_2020
)
SELECT 
    b.geoid,
    b.pop_total,
    b.pop_white_alone_total,
    -- Use COALESCE to force 0s instead of NULLs for blocks with no jobs
    COALESCE(l.c000, 0) AS jobs_total,
    COALESCE(l.ce03, 0) AS jobs_over_40k_total,
    COALESCE(l.c000 - l.ce03, 0) AS jobs_under_40k_total
FROM block_join b
LEFT JOIN lodes_mn_2023 l 
    ON b.geoid = l.w_geocode::TEXT;

/* Apportion the block group level data down to the block level based on the percent of the block group population each block has. 
This allows us to have estimates of all our variables at the block level. */
DROP TABLE IF EXISTS blocks_apportioned;
CREATE TABLE blocks_apportioned AS
WITH bg_pop AS ( -- Sum of the 2020 population and the total count of blocks in each block group    
    SELECT 
        SUBSTRING(geoid, 1, 12) AS bg_geoid,
        SUM(pop_total) AS bg_pop,
        COUNT(geoid) AS block_count
    FROM block_clean
    GROUP BY SUBSTRING(geoid, 1, 12) -- group by the block group ID to aggregate up to the block group level
),
block_weights AS ( -- The specific distribution weight for each block based on its share of the total block group population
    SELECT 
        b.geoid,
        b.pop_total,
        b.pop_white_alone_total,
        b.jobs_total,
        b.jobs_over_40k_total,
        b.jobs_under_40k_total,
        SUBSTRING(b.geoid, 1, 12) AS bg_geoid,
        CASE 
            WHEN bp.bg_pop > 0 THEN (b.pop_total::NUMERIC / bp.bg_pop) -- Use 2020 population ratio in most cases.
            ELSE (1.0 / bp.block_count) -- If the 2020 pop was 0, instead distribute evenly among the blocks
        END AS block_weight
    FROM block_clean b
    LEFT JOIN bg_pop bp 
        ON SUBSTRING(b.geoid, 1, 12) = bp.bg_geoid
)
SELECT 
    bw.geoid,
    bw.pop_total,
    bw.pop_white_alone_total,
    bw.jobs_total,
    bw.jobs_over_40k_total,
    bw.jobs_under_40k_total,
    bg.median_income,
    -- Apportion ACS block group data based on our pre-calculated block weight. Calculation type should be nummeric because block_weight is, avoiding int rounding.
    COALESCE(bg.income_total * bw.block_weight, 0) AS income_total,
    COALESCE(bg.households_total * bw.block_weight, 0) AS households_total,
    COALESCE(bg.hh_no_car_total * bw.block_weight, 0) AS hh_no_car_total,
    COALESCE(bg.pop_25_plus_total * bw.block_weight, 0) AS pop_25_plus_total,
    COALESCE(bg.bachelors_plus_total * bw.block_weight, 0) AS bachelors_plus_total,
    COALESCE(bg.workers_16_plus_total * bw.block_weight, 0) AS workers_16_plus_total,
    COALESCE(bg.drove_alone_total * bw.block_weight, 0) AS drove_alone_total,
    COALESCE(bg.carpooled_total * bw.block_weight, 0) AS carpooled_total,
    COALESCE(bg.took_transit_total * bw.block_weight, 0) AS took_transit_total,
    COALESCE(bg.worked_from_home_total * bw.block_weight, 0) AS worked_from_home_total
FROM block_weights bw 
LEFT JOIN block_group_clean bg 
    ON bw.bg_geoid = bg.geoid;

/* We can run a quick check to see how much data was lost or gained in the apportionment process. 
We should expect some small amount of loss/gain due to rounding, but if we see large swings that could indicate a problem with our apportionment. */
SELECT 
    bg.geoid AS bg_geoid,
    bg.households_total AS original_acs_hh,
    SUM(ba.households_total) AS apportioned_hh_sum,
    bg.households_total - SUM(ba.households_total) AS households_lost -- Calculate the exact loss/gain
FROM block_group_clean bg
LEFT JOIN blocks_apportioned ba 
    ON bg.geoid = SUBSTRING(ba.geoid, 1, 12)
GROUP BY 
    bg.geoid, 
    bg.households_total
HAVING ABS(bg.households_total - SUM(ba.households_total)) > 0.01 -- Only show block groups where data was lost or gained (ignoring float math variances)
ORDER BY ABS(bg.households_total - SUM(ba.households_total)) DESC;

/* Create spatial and b-tree indexes on the shape columns of our block geometry table to speed up our spatial joins. */
CREATE INDEX IF NOT EXISTS idx_block_geom_shape ON block_geom USING GIST (shape);
CREATE INDEX IF NOT EXISTS idx_block_geom_bg ON block_geom (SUBSTRING(geoid, 1, 12));
ANALYZE block_geom;

/* Find a center point of each building footprint and save to a temporary table. */
DROP TABLE IF EXISTS temp_building_points;
CREATE TEMP TABLE temp_building_points AS
SELECT 
    objectid, 
    shape, -- this will save the footprint geometry.
	blockgroupid, -- Since it exists in the dataset already, we can use it to simplify spatial joins so the database is only checking for intersects with blocks within the same block group.
    ST_PointOnSurface(shape) AS pt_geom, -- this will be just a point for faster spatial joins, by using pointonsurface we ensure the point is always on the building footprint.
    ST_Area(shape) AS building_area_sqm -- need this for later to calculate the relative share of land each building takes up. Should be in square meters since the original data is UTM 15N.
FROM metro_buildings;
CREATE INDEX IF NOT EXISTS idx_temp_pts ON temp_building_points USING GIST (pt_geom);
ANALYZE temp_building_points;

/* Now we need to subdivide the land use polygons to optimize our spatial joins. 
This is because the land use polygons are very large and complex. 
By subdividing them into smaller pieces, the query planner can use extent-based optimizations. */
DROP TABLE IF EXISTS landuse_subdivided;
CREATE TEMP TABLE landuse_subdivided AS
SELECT 
    desc2020, 
    ST_Subdivide(shape) AS shape 
FROM generalizedlanduse2020;
CREATE INDEX idx_landuse_sub ON landuse_subdivided USING GIST (shape);
ANALYZE landuse_subdivided;

/* Now we can do our spatial join to attach land use categories and census block geoids to each building. */
DROP TABLE IF EXISTS buildings_enriched;
CREATE TABLE buildings_enriched AS
SELECT DISTINCT ON (b.objectid) -- use distinct on to avoid duplicate rows for buildings that intersect multiple land use polygons, this will keep only the first match.
    b.objectid, 
    b.shape,
    b.building_area_sqm, 
    l.desc2020 AS landuse, -- this will be a foreign key to the land use category we will set up later.
    cb.geoid AS census_block_geoid 
FROM temp_building_points b
LEFT JOIN landuse_subdivided l -- joins in the land use category from the optimized land use table.
    ON ST_Intersects(b.pt_geom, l.shape)
LEFT JOIN block_geom cb 
    ON ST_Intersects(b.pt_geom, cb.shape) -- joins in the census block id.
ORDER BY b.objectid, cb.geoid DESC, l.desc2020 DESC; -- order by objectid to ensure the distinct on works, use buildings with useful data when there are multiple matches.

/* Now we can create a dictionary table to map land use descriptions to building categories. */
DROP TABLE IF EXISTS landuse_category_dict;
CREATE TABLE landuse_category_dict (
    landuse TEXT PRIMARY KEY, -- The land use description from the generalizedlanduse2020 table
    building_category TEXT);
INSERT INTO landuse_category_dict (landuse, building_category) VALUES
    ('Single Family Detached', 'Residential'),
    ('Single Family Attached', 'Residential'),
    ('Multifamily', 'Residential'),
    ('Manufactured Housing Park', 'Residential'),
    ('Farmstead', 'Residential'),
    ('Seasonal/Vacation', 'Residential'),
    ('Retail and Other Commercial', 'Job Site'),
    ('Office', 'Job Site'),
    ('Industrial or Utility', 'Job Site'),
    ('Institutional', 'Job Site'),
    ('Airport or Airstrip', 'Job Site'),
    ('Extractive', 'Job Site'),
    ('Mixed Use Residential', 'Both'),
    ('Mixed Use Industrial', 'Both'),
    ('Mixed Use Commercial', 'Both'),
    ('Agricultural', 'None'),
    ('Park, Recreational, or Preserve', 'None'),
    ('Golf Course', 'None'),
    ('Major Highway', 'None'),
    ('Major Railway', 'None'),
    ('Undeveloped', 'None'),
    ('Open Water', 'None');

/* Apportion the demographic and economic data to each building based on its land use category. 
   Assign weights based on the building's area. Assumes a 4 over 1 ratio (80%/20%) for residential to job site weighting in mixed use areas. */
DROP TABLE IF EXISTS buildings_apportioned;

CREATE TABLE buildings_apportioned AS
WITH bldg_cat AS ( 
    -- Categorize the buildings as job site or residential with the land use dictionary.
    SELECT 
        b.objectid,
        b.shape,
        b.census_block_geoid,
        b.building_area_sqm,
        b.landuse,
        COALESCE(d.building_category, 'None') AS category -- In case no land use category is found for some reason, classify as 'None'
    FROM buildings_enriched b
    LEFT JOIN landuse_category_dict d 
        ON b.landuse = d.landuse
),
bldg_adjusted AS (
    SELECT 
        objectid,
        shape,
        census_block_geoid,
        building_area_sqm,
        landuse,
        category,
        -- For mixed use buildings assume 80% residential to prevent them from receiving equal weighting to fully residential.
        CASE WHEN category = 'Residential' THEN building_area_sqm 
             WHEN category = 'Both' THEN building_area_sqm * 0.8 
             ELSE 0 END AS adj_res_area,
        -- For mixed use buildings assume 20% job site to prevent them from receiving equal weighting to full commercial.
        CASE WHEN category = 'Job Site' THEN building_area_sqm 
             WHEN category = 'Both' THEN building_area_sqm * 0.2 
             ELSE 0 END AS adj_job_area,
        -- Create a fallback area that excludes 'None' areas that should have no weight for blocks missing their target category.
        CASE WHEN category != 'None' THEN building_area_sqm ELSE 0 END AS fallback_area
    FROM bldg_cat
),
bldg_block_totals AS (
    SELECT 
        objectid,
        shape,
        census_block_geoid,
        landuse,
        building_area_sqm,
        category,
        adj_res_area,
        adj_job_area,
        fallback_area,
        -- Window functions to calculate the exact denominators per block to group totals
        SUM(adj_res_area) OVER (PARTITION BY census_block_geoid) AS tot_adj_res,
        SUM(adj_job_area) OVER (PARTITION BY census_block_geoid) AS tot_adj_job,
        SUM(fallback_area) OVER (PARTITION BY census_block_geoid) AS tot_fallback,
        SUM(building_area_sqm) OVER (PARTITION BY census_block_geoid) AS tot_absolute
    FROM bldg_adjusted
),
bldg_weights AS (
    SELECT 
        objectid,
        shape,
        census_block_geoid,
        landuse,
        building_area_sqm,
        -- Residential weight assignment with a 4 tier fallback system:
        CASE 
            WHEN tot_adj_res > 0 THEN (adj_res_area / tot_adj_res) -- 1. Use Residential and Both buildings
            WHEN tot_fallback > 0 THEN (fallback_area / NULLIF(tot_fallback, 0)) -- 2. Fallback: weight by total building area (excluding 'None')
            ELSE (building_area_sqm / NULLIF(tot_absolute, 0)) -- 3. Fallback: Use 'None' buildings if that's all there is
        END AS res_weight, -- 4. If no residential buildings, weight for the block will be null. This will be caught in the next step and assigned 1 to the block geometry to ensure all population is still assigned.
        -- Job weight assignment with a 4 tier fallback system:
        CASE 
            WHEN tot_adj_job > 0 THEN (adj_job_area / tot_adj_job) -- 1. Use Job and Both buildings
            WHEN tot_fallback > 0 THEN (fallback_area / NULLIF(tot_fallback, 0)) -- 2. Fallback: weight by total building area (excluding 'None')
            ELSE (building_area_sqm / NULLIF(tot_absolute, 0)) -- 3. Fallback: Use 'None' buildings if that's all there is
        END AS job_weight -- 4. If no job buildings, weight for the block will be null. This will be caught in the next step and assigned 1 to the block geometry to ensure all jobs are still assigned.
    FROM bldg_block_totals
),
joined_data AS ( -- join the weights back to the block level data and apply the 4th tier of fallback to ensure all blocks get 1.0 apportionment even if they are missing building categories.
    SELECT 
        COALESCE(bw.objectid::TEXT, ba.geoid) AS original_id, -- fallback to block geoid if no building is found.
        COALESCE(bw.shape, bg.shape) AS shape, -- fallback to block geo if no buildings within.
        ba.geoid AS census_block_geoid,
        COALESCE(bw.landuse, 'Block Geometry Fallback') AS landuse, -- tag the land use field with a fallback label for blocks with no buildings.
        COALESCE(bw.building_area_sqm, 0) AS building_area_sqm, -- if no buildings, area is 0.
        COALESCE(bw.res_weight, 1.0) AS res_weight, -- if no building, give a weight of 1 so the block level data is fully assigned to the block geometry instead.
        COALESCE(bw.job_weight, 1.0) AS job_weight, -- if no building, give a weight of 1 so the block level data is fully assigned to the block geometry instead.
        ba.pop_total,
        ba.pop_white_alone_total,
        ba.households_total,
        ba.hh_no_car_total,
        ba.income_total,
        ba.pop_25_plus_total,
        ba.bachelors_plus_total,
        ba.workers_16_plus_total,
        ba.drove_alone_total,
        ba.carpooled_total,
        ba.took_transit_total,
        ba.worked_from_home_total,
        ba.jobs_total,
        ba.jobs_over_40k_total,
        ba.jobs_under_40k_total,
        ba.median_income
    FROM blocks_apportioned ba
    LEFT JOIN block_geom bg 
        ON ba.geoid = bg.geoid
    LEFT JOIN bldg_weights bw 
        ON ba.geoid = bw.census_block_geoid
)
SELECT -- as a last step we apply the weights to apportion the block level data.
    ROW_NUMBER() OVER () AS objectid, -- create a new unique ID for the building level table.
    original_id, -- saves the original building objectid or block geoid for reference and potential debugging.
    shape, -- will be a building footprint for rows with building data, and a block geometry for rows that are just the block fallback.
    census_block_geoid, -- the census block geoid to track which block each building belongs to.
    landuse, -- the land use category, will be 'Block Geometry Fallback' for the rows that are just the block geometry with no building.
    building_area_sqm, -- area of the building footprint.
    res_weight, -- weight for apportioning residential variables, will be 1 for block geometry fallbacks.
    job_weight, -- weight for apportioning job variables, will be 1 for block geometry fallbacks.
    median_income AS expected_median_income, -- median income doesn't get apportioned since it's a ratio variable, not a total count.
    -- apportion the block population data to the residential buildings using the weights.
    (pop_total * res_weight) AS pop_total,
    (pop_white_alone_total * res_weight) AS pop_white_alone_total,
    (households_total * res_weight) AS households_total,
    (hh_no_car_total * res_weight) AS hh_no_car_total,
    (income_total * res_weight) AS income_total,
    (pop_25_plus_total * res_weight) AS pop_25_plus_total,
    (bachelors_plus_total * res_weight) AS bachelors_plus_total,
    (workers_16_plus_total * res_weight) AS workers_16_plus_total,
    (drove_alone_total * res_weight) AS drove_alone_total,
    (carpooled_total * res_weight) AS carpooled_total,
    (took_transit_total * res_weight) AS took_transit_total,
    (worked_from_home_total * res_weight) AS worked_from_home_total,
    -- apportion the block job data to the job site buildings using the weights.
    (jobs_total * job_weight) AS jobs_total,
    (jobs_over_40k_total * job_weight) AS jobs_over_40k_total,
    (jobs_under_40k_total * job_weight) AS jobs_under_40k_total
FROM joined_data
WHERE landuse != 'Block Geometry Fallback' 
   OR (COALESCE(pop_total, 0) > 0 OR COALESCE(jobs_total, 0) > 0); -- filter out the block geometry fallbacks that have no population or jobs after apportionment.


/* And FINALLY, we can apportion to a hex grid for use. */
CREATE INDEX IF NOT EXISTS idx_hex_grid_shape ON hex_grid USING GIST (shape); -- index the hex grid shape for faster spatial joins.
ANALYZE hex_grid;
DROP TABLE IF EXISTS temp_building_points;
CREATE TEMP TABLE temp_building_points AS
SELECT 
    objectid, 
    ST_PointOnSurface(shape) AS shape, -- use the building centroid for spatial joins to the hex grid.
    pop_total,
    pop_white_alone_total,
    households_total,
    hh_no_car_total,
    income_total,
    pop_25_plus_total,
    bachelors_plus_total,
    workers_16_plus_total,
    drove_alone_total,
    carpooled_total,
    took_transit_total,
    worked_from_home_total,
    jobs_total,
    jobs_over_40k_total,
    jobs_under_40k_total
FROM buildings_apportioned;
CREATE INDEX IF NOT EXISTS idx_temp_pts ON temp_building_points USING GIST (shape);
DROP TABLE IF EXISTS temp_metro_boundary;
CREATE TEMP TABLE temp_metro_boundary AS
SELECT ST_Union(shape) as geom 
FROM generalizedlanduse2020;
DROP TABLE IF EXISTS hex_apportioned;
CREATE TABLE hex_apportioned AS
WITH hexes_aggregated AS ( -- spatial join to hexes to aggregate the apportioned building data up to the hex level.
    SELECT 
        h.grid_id,
        h.shape,
        -- Aggregate all the apportioned demographic and economic counts
        COALESCE(SUM(b.pop_total), 0) AS pop_total,
        COALESCE(SUM(b.pop_white_alone_total), 0) AS pop_white_alone_total,
        COALESCE(SUM(b.households_total), 0) AS households_total,
        COALESCE(SUM(b.hh_no_car_total), 0) AS hh_no_car_total,
        COALESCE(SUM(b.pop_25_plus_total), 0) AS pop_25_plus_total,
        COALESCE(SUM(b.bachelors_plus_total), 0) AS bachelors_plus_total,
        COALESCE(SUM(b.workers_16_plus_total), 0) AS workers_16_plus_total,
        COALESCE(SUM(b.drove_alone_total), 0) AS drove_alone_total,
        COALESCE(SUM(b.carpooled_total), 0) AS carpooled_total,
        COALESCE(SUM(b.took_transit_total), 0) AS took_transit_total,
        COALESCE(SUM(b.worked_from_home_total), 0) AS worked_from_home_total,
        COALESCE(SUM(b.jobs_total), 0) AS jobs_total,
        COALESCE(SUM(b.jobs_over_40k_total), 0) AS jobs_over_40k_total,
        COALESCE(SUM(b.jobs_under_40k_total), 0) AS jobs_under_40k_total,
        COALESCE(SUM(b.income_total), 0) AS income_total
    FROM hex_grid h
    INNER JOIN temp_metro_boundary mb 
        ON ST_Intersects(h.shape, mb.geom) -- only consider hexes that intersect the metro area to speed up the query and avoid assigning data to hexes that are fully outside the metro area.
    LEFT JOIN temp_building_points b 
        ON ST_Intersects(b.shape, h.shape)
    GROUP BY 
        h.grid_id, 
        h.shape
)
SELECT
    ROW_NUMBER() OVER() AS objectid, -- gis needs this even though we have a grid_id.
    grid_id,
    shape,
    pop_total,
    pop_white_alone_total,
    COALESCE(1.0 - (pop_white_alone_total / NULLIF(pop_total, 0)), 0) AS non_white_pct, -- diversity proxy, calculate the percent of the population that is not white alone.
    households_total,
    hh_no_car_total,
    COALESCE(hh_no_car_total / NULLIF(households_total, 0), 0) AS hh_no_car_pct, -- calculate the percent of households with no car for transportation analysis.
    income_total,
    COALESCE(income_total / NULLIF(pop_total, 0), 0) AS per_capita_income, -- calculate per capita income for economic analysis.
    pop_25_plus_total,
    bachelors_plus_total,
    COALESCE(bachelors_plus_total / NULLIF(pop_25_plus_total, 0), 0) AS bachelors_plus_pct, -- calculate the percent of the population with a bachelors degree or higher for education analysis.
    workers_16_plus_total,
    drove_alone_total,
    COALESCE(drove_alone_total / NULLIF(workers_16_plus_total, 0), 0) AS drove_alone_pct, -- calculate the percent of workers that drove alone for transportation analysis.
    carpooled_total,
    COALESCE(carpooled_total / NULLIF(workers_16_plus_total, 0), 0) AS carpooled_pct, -- calculate the percent of workers that carpooled for transportation analysis.
    took_transit_total,
    COALESCE(took_transit_total / NULLIF(workers_16_plus_total, 0), 0) AS took_transit_pct, -- calculate the percent of workers that took transit for transportation analysis.
    worked_from_home_total,
    COALESCE(worked_from_home_total / NULLIF(workers_16_plus_total, 0), 0) AS worked_from_home_pct, -- calculate the percent of workers that worked from home for transportation analysis.
    jobs_total,
    jobs_over_40k_total,
    COALESCE(jobs_over_40k_total / NULLIF(jobs_total, 0), 0) AS jobs_over_40k_pct, -- calculate the percent of jobs that are over 40k for economic analysis.
    jobs_under_40k_total,
    COALESCE(jobs_under_40k_total / NULLIF(jobs_total, 0), 0) AS jobs_under_40k_pct, -- calculate the percent of jobs that are under 40k for economic analysis.
    COALESCE(jobs_total / NULLIF(households_total, 0), 0) AS jobs_per_household -- calculate the ratio of households and jobs to highlight areas with an unbalance between residential and employment opportunities.
FROM hexes_aggregated;

/* Run a final check to see if the data loss from apportionment is within an acceptable range. 
We compare the totals from the hex grid to the original census block totals for the metro area. */
WITH metro_census_totals AS ( -- Summing the census data for only the 7 metro counties
    SELECT
        SUM(pop_total) AS pop_census_total,
        SUM(jobs_total) AS jobs_census_total
    FROM block_clean
    WHERE LEFT(geoid, 5) IN ('27003', '27019', '27037', '27053', '27123', '27139', '27163') -- metro counties only.
)
SELECT 
    -- Population Totals
    SUM(h.pop_total) AS pop_hex_total,
    c.pop_census_total,
    -- Population Variance
    SUM(h.pop_total) - c.pop_census_total AS pop_delta,
    ROUND(
        ((SUM(h.pop_total) - c.pop_census_total)::NUMERIC / NULLIF(c.pop_census_total, 0)) * 100, 
        5
    ) AS pop_error_pct,
    -- Job Totals
    SUM(h.jobs_total) AS jobs_hex_total,
    c.jobs_census_total,
    -- Job Variance
    SUM(h.jobs_total) - c.jobs_census_total AS job_delta,
    ROUND(
        ((SUM(h.jobs_total) - c.jobs_census_total)::NUMERIC / NULLIF(c.jobs_census_total, 0)) * 100, 
        5
    ) AS job_error_pct
FROM hex_apportioned h
CROSS JOIN metro_census_totals c
GROUP BY c.pop_census_total, c.jobs_census_total;