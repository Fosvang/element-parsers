defmodule Parser do
  use Platform.Parsing.Behaviour
  require Logger

  # ELEMENT IoT Parser for SensoNeo Single Sensor
  # According to documentation provided by Sensoneo
  # Link: https://sensoneo.com/product/smart-sensors/
  #
  # REQUIRED Profile "sensoneo" with fields:
  #   "distance_zero_percent": Integer, distance in cm from sensor if container is "empty"
  #   "distance_hundred_percent": Integer, distance in cm from sensor if container is "full"
  #
  # Changelog
  #   2018-09-13 [as]: Initial version.
  #   2018-09-17 [as]: fixed position value, was switched
  #   2019-09-06 [jb]: Added parsing catchall for unknown payloads.
  #   2019-10-10 [jb]: New implementation for <= v2 payloads.
  #   2019-10-11 [jb]: Supporting v3 payloads.
  #   2020-04-22 [jb]: Added calculated ullage in % from configurable profile
  #

  def ullage_distance_zero_percent(meta) do
    get(
      meta,
      [:device, :fields, :sensoneo, :distance_zero_percent],
      170 # max value the sensor can measure
    )
  end
  def ullage_distance_hundred_percent(meta) do
    get(
      meta,
      [:device, :fields, :sensoneo, :distance_hundred_percent],
      3 # min value the sensor can measure
    )
  end

  def preloads do
    [device: [profile_data: [:profile]]]
  end

  def add_ullage(%{distance: distance} = row, meta) do
    max = ullage_distance_zero_percent(meta)
    min = ullage_distance_hundred_percent(meta)

    Map.merge(row, %{ullage: calculate_ullage_percent(distance, min, max)})
  end
  def add_ullage(row, _meta), do: row

  def calculate_ullage_percent(_distance, min, max) when min == max, do: 100
  def calculate_ullage_percent(distance, min, max) do
    # Move values from min to 0
    distance = distance - min
    max = max - min
    # Calculate percentage
    percent = (1 - (distance / max)) * 100
    # Cap to 0..100 as integer
    percent |> Kernel.min(100) |> Kernel.max(0) |> Kernel.trunc()
  end

  def parse(<<"(", _::binary>> = payload, %{meta: %{frame_port: 1}} = meta) do
    ~r/\(U([0-9.]+)T([0-9+-]+)D([0-9]+)P([0-9]+)\)/
    |> Regex.run(payload)
    |> case do
      [_, voltage, temp, distance, position] ->
        %{
          voltage: String.to_float(voltage),
          temperature: String.to_integer(temp),
          distance: String.to_integer(distance),
          position: position(position)
        }
      _ ->
        Logger.info("Sensoneo Parser: Unknown payload #{inspect payload}")
        []
    end
    |> add_ullage(meta)
  end
  def parse(<<0xFF, 0xFF, header::binary-2, sensor_id::32-little, events, sonar0, sonar1, sonar2, sonar3, voltage, temp, tilt, tx_events>>, %{meta: %{frame_port: 2}} = meta) do
    # Dont know what `qs` is, not documented ...
    <<_qs::4, type::4, firmware::8>> = header
    type = case type do
      0 -> :master
      1 -> :slave
      2 -> :standalone
      _ -> :unknown
    end

    [
      event_measurement_ended: binary_and(events, 0x01),
      event_temperature_threshold: binary_and(events, 0x02),
      event_tilt_threshold: binary_and(events, 0x04),
      event_slave_device_tx: binary_and(events, 0x08),
      event_battery_low: binary_and(events, 0x10),
      event_gpsfix: binary_and(events, 0x20),
      event_startup: binary_and(events, 0x40),
    ]
    |> Enum.filter(fn({_, v}) -> v != 0 end)
    |> Enum.into(%{
      type: type,
      firmware: firmware,
      sensor_id: sensor_id,
      distance: (sonar0*2 + sonar1*2 + sonar2*2 + sonar3*2) / 4,
      sonar_0: sonar0*2, # cm
      sonar_1: sonar1*2, # cm
      sonar_2: sonar2*2, # cm
      sonar_3: sonar3*2, # cm
      voltage: (2500+voltage*10)/1000, # V
      temperature: temp, # C°
      tilt: tilt, # °
      tx_events: tx_events, # Number events
    })
    |> add_ullage(meta)
  end
  def parse(payload, meta) do
    Logger.warn("Could not parse payload #{inspect payload} with frame_port #{inspect get_in(meta, [:meta, :frame_port])}")
    []
  end

  defp binary_and(events, pattern) do
    require Bitwise
    case Bitwise.band(events, pattern) do
      0 -> 0
      _ -> 1
    end
  end

  defp position("0"), do: "tilt"
  defp position("1"), do: "normal"
  defp position(_), do: "unknown"

  def fields do
    [
      %{
        field: "ullage",
        display: "Ullage",
        unit: "%"
      },
      %{
        field: "distance",
        display: "Distance",
        unit: "cm"
      },
      %{
        field: "voltage",
        display: "Voltage",
        unit: "V"
      },
      %{
        field: "temperature",
        display: "Temperature",
        unit: "°C"
      },
      %{
        field: "position",
        display: "Position"
      },
      %{
        field: "tilt",
        display: "Tilt",
        unit: "°"
      },
      %{
        field: "sonar_0",
        display: "Sonar0",
        unit: "cm"
      },
      %{
        field: "sonar_1",
        display: "Sonar1",
        unit: "cm"
      },
      %{
        field: "sonar_2",
        display: "Sonar2",
        unit: "cm"
      },
      %{
        field: "sonar_3",
        display: "Sonar3",
        unit: "cm"
      },
    ]
  end

  def tests() do
    [
      # Version 1 or 2
      {
        :parse_hex,
        "2855332E3736542B313444323531503129",
        %{meta: %{frame_port: 1}},
        %{distance: 251, position: "normal", temperature: 14, ullage: 0, voltage: 3.76}
      },

      # Version 3
      {
        :parse_hex,
        "FFFF22B39C009070017F7F7F7F6D15325D",
        %{meta: %{frame_port: 2}},
        %{
          distance: 254.0,
          event_measurement_ended: 1,
          firmware: 179,
          sensor_id: 1888485532,
          sonar_0: 254,
          sonar_1: 254,
          sonar_2: 254,
          sonar_3: 254,
          temperature: 21,
          tilt: 50,
          tx_events: 93,
          type: :standalone,
          ullage: 0,
          voltage: 3.59
        }
      },

      # Version 3 with profile
      {
        :parse_hex,
        "FFFF22B39C00907001101010106D15325D",
        %{
          meta: %{frame_port: 2},
          device: %{
            fields: %{
              sensoneo: %{
                distance_zero_percent: 10,
                distance_hundred_percent: 100,
              }
            }
          }
        },
        %{
          distance: 32.0,
          event_measurement_ended: 1,
          firmware: 179,
          sensor_id: 1888485532,
          sonar_0: 32,
          sonar_1: 32,
          sonar_2: 32,
          sonar_3: 32,
          temperature: 21,
          tilt: 50,
          tx_events: 93,
          type: :standalone,
          ullage: 24,
          voltage: 3.59
        }
      },
    ]
  end
end
