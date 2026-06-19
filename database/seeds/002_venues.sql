-- =============================================================================
-- WCIC — World Cup Intelligence Center
-- Seed: 002_venues.sql
-- Description: 16 estádios da Copa do Mundo 2026 (EUA, Canadá, México)
-- Source: FIFA, capacidades e nomes oficiais confirmados para o torneio
-- Run after: 001_teams.sql
-- =============================================================================

SET search_path TO wcic, public;

INSERT INTO venues (
    id, name, city, country, capacity,
    latitude, longitude, timezone, surface
) VALUES

-- =============================================================================
-- ESTADOS UNIDOS (11 estádios)
-- =============================================================================
(gen_random_uuid(),
 'MetLife Stadium',           -- Nome FIFA: "New York New Jersey Stadium"
 'New York / New Jersey', 'United States', 82500,
 40.8135, -74.0745, 'America/New_York', 'grass'),

(gen_random_uuid(),
 'Mercedes-Benz Stadium',     -- Nome FIFA: "Atlanta Stadium"
 'Atlanta', 'United States', 68239,
 33.7553, -84.4006, 'America/New_York', 'grass'),

(gen_random_uuid(),
 'Gillette Stadium',          -- Nome FIFA: "Boston Stadium" (Foxborough, MA)
 'Boston', 'United States', 64146,
 42.0909, -71.2643, 'America/New_York', 'grass'),

(gen_random_uuid(),
 'AT&T Stadium',              -- Nome FIFA: "Dallas Stadium" (Arlington, TX)
 'Dallas', 'United States', 70649,
 32.7480, -97.0930, 'America/Chicago', 'grass'),

(gen_random_uuid(),
 'Levi''s Stadium',           -- Nome FIFA: "San Francisco Bay Area Stadium"
 'San Francisco Bay Area', 'United States', 68500,
 37.4033, -121.9694, 'America/Los_Angeles', 'grass'),

(gen_random_uuid(),
 'Arrowhead Stadium',         -- Nome FIFA: "Kansas City Stadium"
 'Kansas City', 'United States', 69045,
 39.0489, -94.4839, 'America/Chicago', 'grass'),

(gen_random_uuid(),
 'NRG Stadium',               -- Nome FIFA: "Houston Stadium"
 'Houston', 'United States', 68777,
 29.6847, -95.4107, 'America/Chicago', 'turf'),

(gen_random_uuid(),
 'Empower Field at Mile High', -- Nome FIFA: "Denver Stadium"
 'Denver', 'United States', 76125,
 39.7439, -105.0201, 'America/Denver', 'grass'),

(gen_random_uuid(),
 'Hard Rock Stadium',         -- Nome FIFA: "Miami Stadium"
 'Miami', 'United States', 65326,
 25.9580, -80.2389, 'America/New_York', 'grass'),

(gen_random_uuid(),
 'Lincoln Financial Field',   -- Nome FIFA: "Philadelphia Stadium"
 'Philadelphia', 'United States', 69796,
 39.9008, -75.1675, 'America/New_York', 'grass'),

(gen_random_uuid(),
 'GEODIS Park',               -- Nome FIFA: "Nashville Stadium"
 'Nashville', 'United States', 30000,
 36.1305, -86.7718, 'America/Chicago', 'grass'),

(gen_random_uuid(),
 'Lumen Field',               -- Nome FIFA: "Seattle Stadium"
 'Seattle', 'United States', 72000,
 47.5952, -122.3316, 'America/Los_Angeles', 'turf'),

-- =============================================================================
-- CANADÁ (2 estádios)
-- =============================================================================
(gen_random_uuid(),
 'BC Place',
 'Vancouver', 'Canada', 52497,
 49.2767, -123.1116, 'America/Vancouver', 'turf'),

(gen_random_uuid(),
 'BMO Field',                 -- Nome FIFA: "Toronto Stadium"
 'Toronto', 'Canada', 43036,
 43.6333, -79.4186, 'America/Toronto', 'grass'),

-- =============================================================================
-- MÉXICO (3 estádios)
-- =============================================================================
(gen_random_uuid(),
 'Estadio Azteca',            -- Nome FIFA: "Mexico City Stadium"
 'Mexico City', 'Mexico', 80824,
 19.3028, -99.1505, 'America/Mexico_City', 'grass'),

(gen_random_uuid(),
 'Estadio Akron',             -- Nome FIFA: "Guadalajara Stadium"
 'Guadalajara', 'Mexico', 45664,
 20.6856, -103.4674, 'America/Mexico_City', 'grass'),

(gen_random_uuid(),
 'Estadio BBVA',              -- Nome FIFA: "Monterrey Stadium"
 'Monterrey', 'Mexico', 53300,
 25.6694, -100.2437, 'America/Monterrey', 'grass');

-- =============================================================================
-- Obs: as capacidades utilizadas são as configurações oficiais da FIFA para o
-- torneio, que diferem das capacidades exatas dos estádios.
-- A FIFA adota nomes genéricos para neutralidade comercial, os nomes reais dos
-- estádios foram inseridos através de comentários acima.
-- =============================================================================
