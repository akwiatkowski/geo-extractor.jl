# Climate data source for the optional phenology engine in osm-world-viewer.
#
# Design:
# - Providers are swappable: OpenMeteoProvider (network) and SyntheticProvider (deterministic fallback).
# - The extractor fetches climate at build-time and embeds a compact `climate` block in scene.json.gz.
# - Daily arrays hold 365 values (one per day-of-year). Weekly arrays hold 52 values for advanced vars
#   and are computed by simple averaging of the daily source where available.
# - Failures in the network provider fall back to SyntheticProvider automatically so scenes never break.

using Dates
import HTTP
import JSON3

"""Container for the climate normals embedded in a scene."""
struct ClimateSample
    source::String
    elevation::Float64
    reference_period::String
    daily::Dict{String,Vector{Float64}}
    weekly::Dict{String,Vector{Float64}}
end

StructTypes.StructType(::Type{ClimateSample}) = StructTypes.Struct()

"""Base type for climate backends."""
abstract type AbstractClimateProvider end

# ---------------------------------------------------------------------------
# Open-Meteo Historical Weather API provider
# ---------------------------------------------------------------------------

"""
    OpenMeteoProvider(; reference_period="1991-2020", api_base=...)

Provider that fetches daily historical data from the Open-Meteo archive API
(`archive-api.open-meteo.com/v1/archive`) and computes day-of-year normals by
averaging the requested year range. Feb 29 is dropped so every year lines up to
365 days.
"""
struct OpenMeteoProvider <: AbstractClimateProvider
    reference_period::String
    api_base::String
end

function OpenMeteoProvider(; reference_period::String="1991-2020",
                             api_base::String="https://archive-api.open-meteo.com/v1/archive")
    OpenMeteoProvider(reference_period, api_base)
end

function _parse_period(period::String)
    m = match(r"^(\d{4})-(\d{4})$", period)
    m === nothing && error("reference period must be YYYY-YYYY, got: $period")
    return parse(Int, m.captures[1]), parse(Int, m.captures[2])
end

"""Day-of-year 1..365 (Feb 29 is ignored)."""
function _doy365(dt::Date)::Int
    isleapyear(year(dt)) && month(dt) == 2 && day(dt) == 29 && return 0
    doy = dayofyear(dt)
    # After Feb 29 in leap years, shift back by one so Mar 1 stays doy 60.
    if isleapyear(year(dt)) && doy > 60
        return doy - 1
    end
    return doy
end

function _fetch_open_meteo(api_base::String, lat::Real, lon::Real,
                           start_date::String, end_date::String,
                           variables::Vector{String})::Dict
    url = string(api_base,
                 "?latitude=", lat,
                 "&longitude=", lon,
                 "&start_date=", start_date,
                 "&end_date=", end_date,
                 "&daily=", join(variables, ","),
                 "&timezone=GMT")
    resp = HTTP.get(url; status_exception=false, retry=false)
    if resp.status != 200
        body = String(resp.body)
        error("Open-Meteo HTTP $(resp.status): $(body[1:min(200,length(body))])")
    end
    return JSON3.read(String(resp.body))
end

"""Group a flat daily series by day-of-year and average, dropping Feb 29."""
function _daily_normals(times::AbstractVector{Date}, values::Vector{Float64})::Vector{Float64}
    sums = zeros(Float64, 365)
    counts = zeros(Int, 365)
    for (dt, v) in zip(times, values)
        doy = _doy365(dt)
        doy == 0 && continue
        sums[doy] += v
        counts[doy] += 1
    end
    return [counts[doy] > 0 ? sums[doy] / counts[doy] : 0.0 for doy in 1:365]
end

"""Average a 365-day daily array into 52 weekly buckets."""
function _daily_to_weekly(daily::Vector{Float64})::Vector{Float64}
    weekly = zeros(Float64, 52)
    for w in 1:52
        start_d = (w - 1) * 7 + 1
        stop_d = min(w * 7, 365)
        weekly[w] = sum(daily[start_d:stop_d]) / (stop_d - start_d + 1)
    end
    return weekly
end

function fetch_climate(p::OpenMeteoProvider, lat::Real, lon::Real)::ClimateSample
    y0, y1 = _parse_period(p.reference_period)
    # Open-Meteo archive has data from 1940; clamp silently if the requested
    # period is partially unavailable.
    y0 = max(y0, 1940)
    y1 = max(y1, y0)

    variables = ["temperature_2m_max", "temperature_2m_min", "precipitation_sum"]
    data = _fetch_open_meteo(p.api_base, lat, lon, "$y0-01-01", "$y1-12-31", variables)

    daily_data = data[:daily]
    times = Date.(daily_data[:time])
    tmax = _daily_normals(times, collect(Float64, daily_data[:temperature_2m_max]))
    tmin = _daily_normals(times, collect(Float64, daily_data[:temperature_2m_min]))
    tmean = [(mx + mn) / 2 for (mx, mn) in zip(tmax, tmin)]
    precip = _daily_normals(times, collect(Float64, daily_data[:precipitation_sum]))

    # Advanced variables: compute weekly averages from the same archive where possible.
    adv_data = _fetch_open_meteo(p.api_base, lat, lon, "$y0-01-01", "$y1-12-31",
                                 ["snowfall_sum", "wind_speed_10m_max", "sunshine_duration", "shortwave_radiation_sum"])
    adv_daily = adv_data[:daily]
    adv_times = Date.(adv_daily[:time])
    snow = _daily_to_weekly(_daily_normals(adv_times, collect(Float64, adv_daily[:snowfall_sum])))
    wind = _daily_to_weekly(_daily_normals(adv_times, collect(Float64, adv_daily[:wind_speed_10m_max])))
    # sunshine_duration is in seconds per day; convert to hours.
    sunshine_raw = _daily_normals(adv_times, collect(Float64, adv_daily[:sunshine_duration]))
    sunshine = _daily_to_weekly([s / 3600.0 for s in sunshine_raw])
    solar = _daily_to_weekly(_daily_normals(adv_times, collect(Float64, adv_daily[:shortwave_radiation_sum])))
    # Soil moisture is not available as a daily archive variable, so leave zeros
    # as a placeholder; a future provider (ERA5-Land/WorldClim) can fill it.
    soil = zeros(Float64, 52)

    elevation = Float64(get(data, :elevation, 0.0))

    return ClimateSample(
        "open-meteo-archive",
        elevation,
        "$(y0)-$(y1)",
        Dict("temperatureMean" => tmean,
             "temperatureMin" => tmin,
             "temperatureMax" => tmax,
             "precipitation" => precip),
        Dict("snowDepth" => snow,
             "windSpeed" => wind,
             "sunshine" => sunshine,
             "solarRadiation" => solar,
             "soilMoisture" => soil),
    )
end

# ---------------------------------------------------------------------------
# Synthetic latitude-based fallback provider
# ---------------------------------------------------------------------------

"""
    SyntheticProvider(; reference_period="synthetic")

Deterministic fallback that produces plausible annual climate curves from latitude
when the network provider fails. Not scientifically accurate, but keeps scenes
self-contained and phenology-enabled offline.
"""
struct SyntheticProvider <: AbstractClimateProvider
    reference_period::String
end
SyntheticProvider(; reference_period::String="synthetic") = SyntheticProvider(reference_period)

function fetch_climate(p::SyntheticProvider, lat::Real, lon::Real)::ClimateSample
    φ = abs(lat)
    # Annual mean temperature: ~28°C at equator, falling to ~-15°C at pole.
    mean_temp = 28.0 - 0.48 * φ
    # Seasonal amplitude grows with latitude: ~8°C at equator, ~30°C at pole.
    amp = 8.0 + 0.24 * φ
    days = 1:365
    # Coldest day around Jan 15 (doy 15), warmest around Jul 15 (doy 195).
    tmean = [mean_temp - amp * cos(2π * (d - 15) / 365) for d in days]
    tmin = [t - 4.0 for t in tmean]
    tmax = [t + 4.0 for t in tmean]
    # Precipitation: modest base with a summer peak for mid-latitudes; capped.
    precip = [clamp(1.5 + 2.0 * max(0.0, sin(2π * (d - 90) / 365)), 0.0, 12.0) for d in days]

    # Weekly advanced vars: very rough placeholders.
    snow = _daily_to_weekly([t < -2.0 ? clamp(-t * 0.5, 0.0, 5.0) : 0.0 for t in tmean])
    wind = _daily_to_weekly([5.0 + 3.0 * abs(sin(2π * d / 365)) for d in days])
    sunshine = _daily_to_weekly([max(0.0, 12.0 - 0.08 * φ - 6.0 * abs(cos(2π * (d - 15) / 365))) for d in days])
    solar = _daily_to_weekly([max(0.0, 20.0 - 0.15 * φ + 8.0 * sin(2π * (d - 15) / 365)) for d in days])
    soil = zeros(Float64, 52)

    return ClimateSample(
        "synthetic-latitude-fallback",
        0.0,
        p.reference_period,
        Dict("temperatureMean" => tmean, "temperatureMin" => tmin,
             "temperatureMax" => tmax, "precipitation" => precip),
        Dict("snowDepth" => snow, "windSpeed" => wind, "sunshine" => sunshine,
             "solarRadiation" => solar, "soilMoisture" => soil),
    )
end

# ---------------------------------------------------------------------------
# Convenience: fetch with automatic fallback
# ---------------------------------------------------------------------------

"""
    fetch_climate_with_fallback(lat, lon; primary=OpenMeteoProvider(), fallback=SyntheticProvider())

Try the primary provider; on any failure log a warning and use the fallback.
"""
function fetch_climate_with_fallback(lat::Real, lon::Real;
                                     primary::AbstractClimateProvider=OpenMeteoProvider(),
                                     fallback::AbstractClimateProvider=SyntheticProvider())::ClimateSample
    try
        return fetch_climate(primary, lat, lon)
    catch e
        @warn "Climate provider failed, using synthetic fallback" exception=(e, catch_backtrace())
        return fetch_climate(fallback, lat, lon)
    end
end

"""Extractor engine: fetch climate normals for the cell center and store them in
`ctx.extra["climate"]` so the render3d engine can embed them in scene.json."""
function run_climate!(ctx::Ctx)
    sample = fetch_climate_with_fallback(ctx.center.lat, ctx.center.lon)
    ctx.extra["climate"] = sample
    @info "Extractor: climate engine" source=sample.source elevation=sample.elevation reference_period=sample.reference_period
    return nothing
end
