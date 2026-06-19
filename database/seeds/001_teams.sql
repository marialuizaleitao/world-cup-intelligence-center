-- =============================================================================
-- WCIC — World Cup Intelligence Center
-- Seed: 001_teams.sql
-- Description: as 48 seleções classificadas para a Copa do Mundo 2026
-- Source: Sorteio oficial FIFA Washington D.C. em 5 dez 2025
--         Playoffs UEFA e Intercontinentais finalizados em 31 mar 2026
-- Groups: A-L (12 grupos de 4 times, formato novo de 48 seleções)
-- Run after: 004_hypertables.sql
-- =============================================================================

SET search_path TO wcic, public;

INSERT INTO teams (
    id, external_id, name, short_name, country_code,
    confederation, group_name, fifa_ranking, coach
) VALUES

-- =============================================================================
-- GRUPO A — Sede: México
-- =============================================================================
(gen_random_uuid(), 'MEX', 'Mexico',          'MEX', 'MEX', 'CONCACAF', 'A', 16,  'Javier Aguirre'),
(gen_random_uuid(), 'RSA', 'South Africa',    'RSA', 'ZAF', 'CAF',      'A', 58,  'Hugo Broos'),
(gen_random_uuid(), 'KOR', 'South Korea',     'KOR', 'KOR', 'AFC',      'A', 22,  'Hong Myung-bo'),
(gen_random_uuid(), 'CZE', 'Czechia',         'CZE', 'CZE', 'UEFA',     'A', 37,  'Miroslav Koubek'),

-- =============================================================================
-- GRUPO B — Sede: Canadá
-- =============================================================================
(gen_random_uuid(), 'CAN', 'Canada',               'CAN', 'CAN', 'CONCACAF', 'B', 48,  'Jesse Marsch'),
(gen_random_uuid(), 'BIH', 'Bosnia and Herzegovina','BIH', 'BIH', 'UEFA',     'B', 71,  'Sergej Barbarez'),
(gen_random_uuid(), 'QAT', 'Qatar',                'QAT', 'QAT', 'AFC',      'B', 51,  'Julen Lopetegui'),
(gen_random_uuid(), 'SUI', 'Switzerland',          'SUI', 'CHE', 'UEFA',     'B', 17,  'Murat Yakin'),

-- =============================================================================
-- GRUPO C
-- =============================================================================
(gen_random_uuid(), 'BRA', 'Brazil',   'BRA', 'BRA', 'CONMEBOL', 'C', 5,  'Carlo Ancelotti'),
(gen_random_uuid(), 'MAR', 'Morocco',  'MAR', 'MAR', 'CAF',      'C', 14, 'Mohamed Ouahbi'),
(gen_random_uuid(), 'HAI', 'Haiti',    'HAI', 'HTI', 'CONCACAF', 'C', 83, 'Sébastien Migné'),
(gen_random_uuid(), 'SCO', 'Scotland', 'SCO', 'GBR', 'UEFA',     'C', 39, 'Steve Clarke'),

-- =============================================================================
-- GRUPO D — Sede: EUA
-- =============================================================================
(gen_random_uuid(), 'USA', 'United States', 'USA', 'USA', 'CONCACAF', 'D', 11,  'Mauricio Pochettino'),
(gen_random_uuid(), 'PAR', 'Paraguay',      'PAR', 'PRY', 'CONMEBOL', 'D', 63,  'Gustavo Alfaro'),
(gen_random_uuid(), 'AUS', 'Australia',     'AUS', 'AUS', 'AFC',      'D', 23,  'Tony Popovic'),
(gen_random_uuid(), 'TUR', 'Türkiye',       'TUR', 'TUR', 'UEFA',     'D', 26,  'Vincenzo Montella'),

-- =============================================================================
-- GRUPO E
-- =============================================================================
(gen_random_uuid(), 'GER', 'Germany',       'GER', 'DEU', 'UEFA',     'E', 12, 'Julian Nagelsmann'),
(gen_random_uuid(), 'CUW', 'Curaçao',       'CUW', 'CUW', 'CONCACAF', 'E', 88, 'Dick Advocaat'),
(gen_random_uuid(), 'CIV', 'Côte d''Ivoire','CIV', 'CIV', 'CAF',      'E', 30, 'Emerse Faé'),
(gen_random_uuid(), 'ECU', 'Ecuador',       'ECU', 'ECU', 'CONMEBOL', 'E', 42, 'Sebastián Beccacece'),

-- =============================================================================
-- GRUPO F
-- =============================================================================
(gen_random_uuid(), 'NED', 'Netherlands', 'NED', 'NLD', 'UEFA',     'F', 7,  'Ronald Koeman'),
(gen_random_uuid(), 'JPN', 'Japan',       'JPN', 'JPN', 'AFC',      'F', 18, 'Hajime Moriyasu'),
(gen_random_uuid(), 'SWE', 'Sweden',      'SWE', 'SWE', 'UEFA',     'F', 25, 'Jon Dahl Tomasson'),
(gen_random_uuid(), 'TUN', 'Tunisia',     'TUN', 'TUN', 'CAF',      'F', 34, 'Sabri Lamouchi'),

-- =============================================================================
-- GRUPO G
-- =============================================================================
(gen_random_uuid(), 'BEL', 'Belgium',     'BEL', 'BEL', 'UEFA',     'G', 4,  'Rudi Garcia'),
(gen_random_uuid(), 'EGY', 'Egypt',       'EGY', 'EGY', 'CAF',      'G', 38, 'Hossam Hassan'),
(gen_random_uuid(), 'IRN', 'IR Iran',     'IRN', 'IRN', 'AFC',      'G', 29, 'Amir Ghalenoei'),
(gen_random_uuid(), 'NZL', 'New Zealand', 'NZL', 'NZL', 'OFC',      'G', 96, 'Darren Bazeley'),

-- =============================================================================
-- GRUPO H
-- =============================================================================
(gen_random_uuid(), 'ESP', 'Spain',        'ESP', 'ESP', 'UEFA',     'H', 3,  'Luis de la Fuente'),
(gen_random_uuid(), 'CPV', 'Cabo Verde',   'CPV', 'CPV', 'CAF',      'H', 77, 'Pedro Brito "Bubista"'),
(gen_random_uuid(), 'KSA', 'Saudi Arabia', 'KSA', 'SAU', 'AFC',      'H', 56, 'Georgios Donis'),
(gen_random_uuid(), 'URU', 'Uruguay',      'URU', 'URY', 'CONMEBOL', 'H', 17, 'Marcelo Bielsa'),

-- =============================================================================
-- GRUPO I
-- =============================================================================
(gen_random_uuid(), 'FRA', 'France',  'FRA', 'FRA', 'UEFA',     'I', 2,  'Didier Deschamps'),
(gen_random_uuid(), 'SEN', 'Senegal', 'SEN', 'SEN', 'CAF',      'I', 19, 'Pape Thiaw'),
(gen_random_uuid(), 'IRQ', 'Iraq',    'IRQ', 'IRQ', 'AFC',      'I', 58, 'Graham Arnold'),
(gen_random_uuid(), 'NOR', 'Norway',  'NOR', 'NOR', 'UEFA',     'I', 32, 'Ståle Solbakken'),

-- =============================================================================
-- GRUPO J
-- =============================================================================
(gen_random_uuid(), 'ARG', 'Argentina', 'ARG', 'ARG', 'CONMEBOL', 'J', 1,  'Lionel Scaloni'),
(gen_random_uuid(), 'ALG', 'Algeria',   'ALG', 'DZA', 'CAF',      'J', 52, 'Vladimir Petković'),
(gen_random_uuid(), 'AUT', 'Austria',   'AUT', 'AUT', 'UEFA',     'J', 20, 'Ralf Rangnick'),
(gen_random_uuid(), 'JOR', 'Jordan',    'JOR', 'JOR', 'AFC',      'J', 69, 'Jamal Sellami'),

-- =============================================================================
-- GRUPO K
-- =============================================================================
(gen_random_uuid(), 'POR', 'Portugal',    'POR', 'PRT', 'UEFA',     'K', 6,  'Roberto Martínez'),
(gen_random_uuid(), 'COD', 'DR Congo',    'COD', 'COD', 'CAF',      'K', 62, 'Sébastien Desabre'),
(gen_random_uuid(), 'UZB', 'Uzbekistan',  'UZB', 'UZB', 'AFC',      'K', 74, 'Fabio Cannavaro'),
(gen_random_uuid(), 'COL', 'Colombia',    'COL', 'COL', 'CONMEBOL', 'K', 9,  'Néstor Lorenzo'),

-- =============================================================================
-- GRUPO L
-- =============================================================================
(gen_random_uuid(), 'ENG', 'England', 'ENG', 'GBR', 'UEFA',     'L', 5,  'Thomas Tuchel'),
(gen_random_uuid(), 'CRO', 'Croatia', 'CRO', 'HRV', 'UEFA',     'L', 10, 'Zlatko Dalić'),
(gen_random_uuid(), 'GHA', 'Ghana',   'GHA', 'GHA', 'CAF',      'L', 60, 'Carlos Queiroz'),
(gen_random_uuid(), 'PAN', 'Panama',  'PAN', 'PAN', 'CONCACAF', 'L', 43, 'Thomas Christiansen');

-- =============================================================================
-- Obs: external_id será atualizado pelo WF-01 após a primeira sincronização
-- com a API externa. Os IDs acima são códigos FIFA provisórios.
-- =============================================================================
