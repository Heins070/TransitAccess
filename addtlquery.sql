/* Once the travel time matrixes are complete and sent into postGIS you can get the accessibility measures by running this query */
CREATE TABLE transit_analysis AS
WITH transit_join AS( -- aggregate the number of jobs accessible from each origin via transit
SELECT
	t.from_id,
	SUM(h.jobs_total) AS jobs_access_total,
	SUM(h.jobs_over_40k_total) AS jobs_over_40k_access_total
FROM ttmatrix_3hr_transit_30minco t
	LEFT JOIN hex_apportioned h 
		ON t.to_id = h.grid_id
GROUP BY t.from_id
), 
gline_join AS( -- aggregate the number of jobs accessible from each origin via transit after the G Line upgrade
SELECT
	t.from_id,
	SUM(h.jobs_total) AS jobs_access_total,
	SUM(h.jobs_over_40k_total) AS jobs_over_40k_access_total
FROM ttmatrix_3hr_gline_30minco t
	LEFT JOIN hex_apportioned h 
		ON t.to_id = h.grid_id
GROUP BY t.from_id
),
car_join AS( -- aggregate the number of jobs accessible from each origin via car
SELECT
	t.from_id,
	SUM(h.jobs_total) AS jobs_access_total,
	SUM(h.jobs_over_40k_total) AS jobs_over_40k_access_total
FROM ttmatrix_3hr_car_30minco t
	LEFT JOIN hex_apportioned h 
		ON t.to_id = h.grid_id
GROUP BY t.from_id
)
SELECT
	h.*,
	c.jobs_access_total AS car_jobs_access_total,
	c.jobs_over_40k_access_total AS car_jobs_over_40k_access_total,
	t.jobs_access_total AS transit_jobs_access_total,
	t.jobs_over_40k_access_total AS transit_jobs_over_40k_access_total,
	g.jobs_access_total AS g_jobs_access_total,
	g.jobs_over_40k_access_total AS g_jobs_over_40k_access_total,
	c.jobs_access_total - t.jobs_access_total AS modal_gap, -- how many more jobs a car can access than transit
	c.jobs_access_total - g.jobs_access_total AS modal_gap_g, -- how many more jobs a car can access than the new G Line
	g.jobs_access_total - t.jobs_access_total AS access_improvement -- How many more jobs the new g line can access than the old transit network
FROM hex_apportioned h
	LEFT JOIN car_join c
		ON c.from_id = h.grid_id
	LEFT JOIN transit_join t
		ON t.from_id = h.grid_id
	LEFT JOIN gline_join g
		ON g.from_id = h.grid_id;