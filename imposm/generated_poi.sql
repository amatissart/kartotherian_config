CREATE OR REPLACE FUNCTION slice_language_tags(tags hstore)
RETURNS hstore AS $$
    SELECT delete_empty_keys(slice(tags, ARRAY['name:ar', 'name:az', 'name:be', 'name:bg', 'name:br', 'name:bs', 'name:ca', 'name:cs', 'name:cy', 'name:da', 'name:de', 'name:el', 'name:en', 'name:eo', 'name:es', 'name:et', 'name:fi', 'name:fr', 'name:fy', 'name:ga', 'name:gd', 'name:he', 'name:hr', 'name:hu', 'name:hy', 'name:is', 'name:it', 'name:ja', 'name:ja_kana', 'name:ja_rm', 'name:ka', 'name:kk', 'name:kn', 'name:ko', 'name:ko_rm', 'name:la', 'name:lb', 'name:lt', 'name:lv', 'name:mk', 'name:mt', 'name:nl', 'name:no', 'name:pl', 'name:pt', 'name:rm', 'name:ro', 'name:ru', 'name:sk', 'name:sl', 'name:sq', 'name:sr', 'name:sr-Latn', 'name:sv', 'name:th', 'name:tr', 'name:uk', 'name:zh', 'int_name', 'loc_name', 'name', 'wikidata', 'wikipedia']))
$$ LANGUAGE SQL IMMUTABLE;
DO $$ BEGIN RAISE NOTICE 'Layer poi'; END$$;DO $$
BEGIN
    IF NOT EXISTS (SELECT 1
                   FROM pg_type
                   WHERE typname = 'public_transport_stop_type') THEN
        CREATE TYPE public_transport_stop_type AS ENUM (
          'subway', 'tram_stop', 'bus_station', 'bus_stop'
        );
    END IF;
END
$$;
DROP TRIGGER IF EXISTS trigger_flag ON osm_poi_polygon;
DROP TRIGGER IF EXISTS trigger_refresh ON poi_polygon.updates;

-- etldoc:  osm_poi_polygon ->  osm_poi_polygon

CREATE OR REPLACE FUNCTION update_poi_polygon() RETURNS VOID AS $$
BEGIN
  UPDATE osm_poi_polygon
  SET geometry =
           CASE WHEN ST_NPoints(ST_ConvexHull(geometry))=ST_NPoints(geometry)
           THEN ST_Centroid(geometry)
           ELSE ST_PointOnSurface(geometry)
    END
  WHERE ST_GeometryType(geometry) <> 'ST_Point';

  UPDATE osm_poi_polygon
  SET subclass = 'subway'
  WHERE station = 'subway' and subclass='station';

  UPDATE osm_poi_polygon
    SET subclass = 'halt'
    WHERE funicular = 'yes' and subclass='station';

  UPDATE osm_poi_polygon
  SET tags = update_tags(tags, geometry)
  WHERE COALESCE(tags->'name:latin', tags->'name:nonlatin', tags->'name_int') IS NULL;

  ANALYZE osm_poi_polygon;
END;
$$ LANGUAGE plpgsql;

SELECT update_poi_polygon();

-- Handle updates

CREATE SCHEMA IF NOT EXISTS poi_polygon;

CREATE TABLE IF NOT EXISTS poi_polygon.updates(id serial primary key, t text, unique (t));
CREATE OR REPLACE FUNCTION poi_polygon.flag() RETURNS trigger AS $$
BEGIN
    INSERT INTO poi_polygon.updates(t) VALUES ('y')  ON CONFLICT(t) DO NOTHING;
    RETURN null;
END;
$$ language plpgsql;

CREATE OR REPLACE FUNCTION poi_polygon.refresh() RETURNS trigger AS
  $BODY$
  BEGIN
    RAISE LOG 'Refresh poi_polygon';
    PERFORM update_poi_polygon();
    DELETE FROM poi_polygon.updates;
    RETURN null;
  END;
  $BODY$
language plpgsql;

CREATE TRIGGER trigger_flag
    AFTER INSERT OR UPDATE OR DELETE ON osm_poi_polygon
    FOR EACH STATEMENT
    EXECUTE PROCEDURE poi_polygon.flag();

CREATE CONSTRAINT TRIGGER trigger_refresh
    AFTER INSERT ON poi_polygon.updates
    INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE PROCEDURE poi_polygon.refresh();
DROP TRIGGER IF EXISTS trigger_flag ON osm_poi_point;
DROP TRIGGER IF EXISTS trigger_refresh ON poi_point.updates;

-- etldoc:  osm_poi_point ->  osm_poi_point
CREATE OR REPLACE FUNCTION update_osm_poi_point() RETURNS VOID AS $$
BEGIN
  UPDATE osm_poi_point
    SET subclass = 'subway'
    WHERE station = 'subway' and subclass='station';

  UPDATE osm_poi_point
    SET subclass = 'halt'
    WHERE funicular = 'yes' and subclass='station';

  UPDATE osm_poi_point
  SET tags = update_tags(tags, geometry)
  WHERE COALESCE(tags->'name:latin', tags->'name:nonlatin', tags->'name_int') IS NULL;

END;
$$ LANGUAGE plpgsql;

SELECT update_osm_poi_point();

CREATE OR REPLACE FUNCTION update_osm_poi_point_agg() RETURNS VOID AS $$
BEGIN
  UPDATE osm_poi_point p
  SET agg_stop = CASE
      WHEN p.subclass IN ('bus_stop', 'bus_station', 'tram_stop', 'subway')
        THEN 1
      ELSE NULL
  END;

  UPDATE osm_poi_point p
    SET agg_stop = (
      CASE
        WHEN p.subclass IN ('bus_stop', 'bus_station', 'tram_stop', 'subway')
            AND r.rk IS NULL OR r.rk = 1
          THEN 1
        ELSE NULL
      END)
    FROM osm_poi_stop_rank r
    WHERE p.osm_id = r.osm_id
  ;

END;
$$ LANGUAGE plpgsql;

-- Handle updates

CREATE SCHEMA IF NOT EXISTS poi_point;

CREATE TABLE IF NOT EXISTS poi_point.updates(id serial primary key, t text, unique (t));
CREATE OR REPLACE FUNCTION poi_point.flag() RETURNS trigger AS $$
BEGIN
    INSERT INTO poi_point.updates(t) VALUES ('y')  ON CONFLICT(t) DO NOTHING;
    RETURN null;
END;
$$ language plpgsql;

CREATE OR REPLACE FUNCTION poi_point.refresh() RETURNS trigger AS
  $BODY$
  BEGIN
    RAISE LOG 'Refresh poi_point';
    PERFORM update_osm_poi_point();
    REFRESH MATERIALIZED VIEW osm_poi_stop_centroid;
    REFRESH MATERIALIZED VIEW osm_poi_stop_rank;
    PERFORM update_osm_poi_point_agg();
    DELETE FROM poi_point.updates;
    RETURN null;
  END;
  $BODY$
language plpgsql;

CREATE TRIGGER trigger_flag
    AFTER INSERT OR UPDATE OR DELETE ON osm_poi_point
    FOR EACH STATEMENT
    EXECUTE PROCEDURE poi_point.flag();

CREATE CONSTRAINT TRIGGER trigger_refresh
    AFTER INSERT ON poi_point.updates
    INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE PROCEDURE poi_point.refresh();
CREATE OR REPLACE FUNCTION poi_class_rank(class TEXT)
RETURNS INT AS $$
    SELECT CASE class
        WHEN 'hospital' THEN 20
        WHEN 'park' THEN 25
        WHEN 'cemetery' THEN 30
        WHEN 'railway' THEN 40
        WHEN 'bus' THEN 50
        WHEN 'attraction' THEN 70
        WHEN 'harbor' THEN 75
        WHEN 'college' THEN 80
        WHEN 'school' THEN 85
        WHEN 'stadium' THEN 90
        WHEN 'zoo' THEN 95
        WHEN 'town_hall' THEN 100
        WHEN 'campsite' THEN 110
        WHEN 'cemetery' THEN 115
        WHEN 'park' THEN 120
        WHEN 'library' THEN 130
        WHEN 'police' THEN 135
        WHEN 'post' THEN 140
        WHEN 'golf' THEN 150
        WHEN 'shop' THEN 400
        WHEN 'grocery' THEN 500
        WHEN 'fast_food' THEN 600
        WHEN 'clothing_store' THEN 700
        WHEN 'bar' THEN 800
        ELSE 1000
    END;
$$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION poi_class(subclass TEXT, mapping_key TEXT)
RETURNS TEXT AS $$
    SELECT CASE
        WHEN subclass IN ('accessories','antiques','art','beauty','bed','boutique','camera','carpet','charity','chemist','chocolate','coffee','computer','confectionery','convenience','copyshop','cosmetics','garden_centre','doityourself','erotic','electronics','fabric','florist','furniture','video_games','video','general','gift','hardware','hearing_aids','hifi','ice_cream','interior_decoration','jewelry','kiosk','lamps','mall','massage','motorcycle','mobile_phone','newsagent','optician','outdoor','perfumery','perfume','pet','photo','second_hand','shoes','sports','stationery','tailor','tattoo','ticket','tobacco','toys','travel_agency','watches','weapons','wholesale') THEN 'shop'
        WHEN subclass IN ('townhall','public_building','courthouse','community_centre') THEN 'town_hall'
        WHEN subclass IN ('golf','golf_course','miniature_golf') THEN 'golf'
        WHEN subclass IN ('fast_food','food_court') THEN 'fast_food'
        WHEN subclass IN ('park','bbq') THEN 'park'
        WHEN subclass IN ('bus_stop','bus_station') THEN 'bus'
        WHEN (subclass='station' AND mapping_key = 'railway') OR subclass IN ('halt', 'tram_stop', 'subway') THEN 'railway'
        WHEN (subclass='station' AND mapping_key = 'aerialway') THEN 'aerialway'
        WHEN subclass IN ('camp_site','caravan_site') THEN 'campsite'
        WHEN subclass IN ('laundry','dry_cleaning') THEN 'laundry'
        WHEN subclass IN ('supermarket','deli','delicatessen','department_store','greengrocer','marketplace') THEN 'grocery'
        WHEN subclass IN ('books','library') THEN 'library'
        WHEN subclass IN ('university','college') THEN 'college'
        WHEN subclass IN ('hotel','motel','bed_and_breakfast','guest_house','hostel','chalet','alpine_hut','camp_site') THEN 'lodging'
        WHEN subclass IN ('chocolate','confectionery') THEN 'ice_cream'
        WHEN subclass IN ('post_box','post_office') THEN 'post'
        WHEN subclass IN ('cafe') THEN 'cafe'
        WHEN subclass IN ('school','kindergarten') THEN 'school'
        WHEN subclass IN ('alcohol','beverages','wine') THEN 'alcohol_shop'
        WHEN subclass IN ('bar','nightclub') THEN 'bar'
        WHEN subclass IN ('marina','dock') THEN 'harbor'
        WHEN subclass IN ('car','car_repair','taxi') THEN 'car'
        WHEN subclass IN ('hospital','nursing_home', 'doctors', 'clinic') THEN 'hospital'
        WHEN subclass IN ('grave_yard','cemetery') THEN 'cemetery'
        WHEN subclass IN ('attraction','viewpoint') THEN 'attraction'
        WHEN subclass IN ('biergarten','pub') THEN 'beer'
        WHEN subclass IN ('music','musical_instrument') THEN 'music'
        WHEN subclass IN ('american_football','stadium','soccer','pitch') THEN 'stadium'
        WHEN subclass IN ('accessories','antiques','art','artwork','gallery','arts_centre') THEN 'art_gallery'
        WHEN subclass IN ('bag','clothes') THEN 'clothing_store'
        WHEN subclass IN ('swimming_area','swimming') THEN 'swimming'
        WHEN subclass IN ('castle','ruins') THEN 'castle'
        ELSE subclass
    END;
$$ LANGUAGE SQL IMMUTABLE;
DROP MATERIALIZED VIEW IF EXISTS osm_poi_stop_centroid CASCADE;
CREATE MATERIALIZED VIEW osm_poi_stop_centroid AS (
  SELECT
      uic_ref,
      count(*) as count,
			CASE WHEN count(*) > 2 THEN ST_Centroid(ST_UNION(geometry))
			ELSE NULL END AS centroid
  FROM osm_poi_point
	WHERE
		nullif(uic_ref, '') IS NOT NULL
		AND subclass IN ('bus_stop', 'bus_station', 'tram_stop', 'subway')
	GROUP BY
		uic_ref
	HAVING
		count(*) > 1
);

DROP MATERIALIZED VIEW IF EXISTS osm_poi_stop_rank CASCADE;
CREATE MATERIALIZED VIEW osm_poi_stop_rank AS (
	SELECT
		p.osm_id,
-- 		p.uic_ref,
-- 		p.subclass,
		ROW_NUMBER()
		OVER (
			PARTITION BY p.uic_ref
			ORDER BY
				p.subclass :: public_transport_stop_type NULLS LAST,
				ST_Distance(c.centroid, p.geometry)
		) AS rk
	FROM osm_poi_point p
		INNER JOIN osm_poi_stop_centroid c ON (p.uic_ref = c.uic_ref)
	WHERE
		subclass IN ('bus_stop', 'bus_station', 'tram_stop', 'subway')
	ORDER BY p.uic_ref, rk
);

ALTER TABLE osm_poi_point ADD COLUMN IF NOT EXISTS agg_stop INTEGER DEFAULT NULL;
SELECT update_osm_poi_point_agg();
CREATE OR REPLACE FUNCTION osm_hash_from_imposm(imposm_id bigint)
RETURNS bigint AS $$
    SELECT CASE
        WHEN imposm_id < -1e17 THEN (-imposm_id-1e17) * 10 + 4 -- Relation
        WHEN imposm_id < 0 THEN  (-imposm_id) * 10 + 1 -- Way
        ELSE imposm_id * 10 -- Node
    END::bigint;
$$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION global_id_from_imposm(imposm_id bigint)
RETURNS TEXT AS $$
    SELECT CONCAT(
        'osm:',
        CASE WHEN imposm_id < -1e17 THEN CONCAT('relation:', -imposm_id-1e17)
             WHEN imposm_id < 0 THEN CONCAT('way:', -imposm_id)
             ELSE CONCAT('node:', imposm_id)
        END
    );
$$ LANGUAGE SQL IMMUTABLE;


-- etldoc: layer_poi[shape=record fillcolor=lightpink, style="rounded,filled",
-- etldoc:     label="layer_poi | <z12> z12 | <z13> z13 | <z14_> z14+" ] ;

CREATE OR REPLACE FUNCTION layer_poi(bbox geometry, zoom_level integer, pixel_width numeric)
RETURNS TABLE(osm_id bigint, global_id text, geometry geometry, name text, name_en text, name_de text, tags hstore, class text, subclass text, agg_stop integer, "rank" int) AS $$
    SELECT osm_id_hash AS osm_id, global_id,
        geometry, NULLIF(name, '') AS name,
        COALESCE(NULLIF(name_en, ''), name) AS name_en,
        COALESCE(NULLIF(name_de, ''), name, name_en) AS name_de,
        tags,
        poi_class(subclass, mapping_key) AS class,
        CASE
            WHEN subclass = 'information'
                THEN NULLIF(information, '')
            ELSE subclass
        END AS subclass,
        agg_stop,
        row_number() OVER (
            PARTITION BY LabelGrid(geometry, 100 * pixel_width)
            ORDER BY CASE WHEN name = '' THEN 2000 ELSE poi_class_rank(poi_class(subclass, mapping_key)) END ASC
        )::int AS "rank"
    FROM (
        -- etldoc: osm_poi_point ->  layer_poi:z12
        -- etldoc: osm_poi_point ->  layer_poi:z13
        SELECT *,
            osm_hash_from_imposm(osm_id) AS osm_id_hash,
            global_id_from_imposm(osm_id) as global_id
        FROM osm_poi_point
            WHERE geometry && bbox
                AND zoom_level BETWEEN 12 AND 13
                AND ((subclass='station' AND mapping_key = 'railway')
                    OR subclass IN ('halt', 'ferry_terminal'))
        UNION ALL

        -- etldoc: osm_poi_point ->  layer_poi:z14_
        SELECT *,
            osm_hash_from_imposm(osm_id) AS osm_id_hash,
            global_id_from_imposm(osm_id) as global_id
        FROM osm_poi_point
            WHERE geometry && bbox
                AND zoom_level >= 14

        UNION ALL
        -- etldoc: osm_poi_polygon ->  layer_poi:z12
        -- etldoc: osm_poi_polygon ->  layer_poi:z13
        SELECT *,
            NULL::INTEGER AS agg_stop,
            osm_hash_from_imposm(osm_id) AS osm_id_hash,
            global_id_from_imposm(osm_id) as global_id
        FROM osm_poi_polygon
            WHERE geometry && bbox
                AND zoom_level BETWEEN 12 AND 13
                AND ((subclass='station' AND mapping_key = 'railway')
                    OR subclass IN ('halt', 'ferry_terminal'))

        UNION ALL
        -- etldoc: osm_poi_polygon ->  layer_poi:z14_
        SELECT *,
            NULL::INTEGER AS agg_stop,
            osm_hash_from_imposm(osm_id) AS osm_id_hash,
            global_id_from_imposm(osm_id) as global_id
        FROM osm_poi_polygon
            WHERE geometry && bbox
                AND zoom_level >= 14
        ) as poi_union
    ORDER BY "rank"
    ;
$$ LANGUAGE SQL IMMUTABLE;

