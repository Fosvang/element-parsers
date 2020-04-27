defmodule Parser do
  use Platform.Parsing.Behaviour
  require Logger

  # Parser for conbee HybridTag L300
  # https://www.conbee.eu/wp-content/uploads/HybridTAG-L300-Infosheet_06-18-2.pdf
  #
  # REQUIRED Profile "conbee" with fields:
  #   "distance_zero_percent": Integer, distance in cm from sensor if container is "empty"
  #   "distance_hundred_percent": Integer, distance in cm from sensor if container is "full"
  #
  # Changelog
  #   2018-08-23 [jb]: Initial version implemented using HybridTAG-L300-Infosheet_06-18-2.pdf
  #   2019-03-20 [jb]: Fixed "Humidity Sensor" for real payload.
  #   2019-09-06 [jb]: Added parsing catchall for unknown payloads.
  #   2019-12-27 [jb]: Added field "Proximity in %"
  #   2020-01-08 [jb]: Added fields for Indoor Localization
  #   2020-04-22 [jb]: Added calculated ullage in % from configurable profile
  #

  def ullage_distance_zero_percent(meta) do
    get(
      meta,
      [:device, :fields, :conbee, :distance_zero_percent],
      200 # guessed max value the device can measure
    )
  end
  def ullage_distance_hundred_percent(meta) do
    get(
      meta,
      [:device, :fields, :conbee, :distance_hundred_percent],
      0 # guessed min value the device can measure
    )
  end


  def preloads do
    [device: [profile_data: [:profile]]]
  end


  def parse(data, %{meta: %{frame_port: 1}} = meta) do
    data
    |> parse_packets([])
    |> map_packets
    |> add_ullage(meta)
  end
  def parse(payload, meta) do
    Logger.warn("Could not parse payload #{inspect payload} with frame_port #{inspect get_in(meta, [:meta, :frame_port])}")
    []
  end

  #----------------


  def add_ullage(%{proximity: distance} = row, meta) do
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

  def map_packets(packets) do
    packets
    |> Enum.reduce(%{}, &map_packet/2)
    |> Enum.into(%{})
  end


  # Ambient Light
  def map_packet(<<0x01, 0x01, value::16>>, acc) do
    Map.merge(acc, %{ambient_light: value})
  end

  # Temperature Sensor
  def map_packet(<<0x02, 0x01, value::float-32>>, acc) do
    Map.merge(acc, %{temperature: value})
  end

  # Humidity Sensor
  def map_packet(<<0x03, 0x01, value::8>>, acc) do
    # Documentation states value::16, but there was no example and a real device only sends 8 byte.
    Map.merge(acc, %{humidity: value})
  end

  # Accelerometer
  def map_packet(<<0x04, 0x01, value::signed-16>>, acc) do
    Map.merge(acc, %{accelerate_x: value})
  end
  def map_packet(<<0x04, 0x02, value::signed-16>>, acc) do
    Map.merge(acc, %{accelerate_y: value})
  end
  def map_packet(<<0x04, 0x03, value::signed-16>>, acc) do
    Map.merge(acc, %{accelerate_z: value})
  end

  # Push Button
  def map_packet(<<0x05, 0x01, value::8>>, acc) do
    Map.merge(acc, %{button_1: value})
  end
  def map_packet(<<0x05, 0x02, value::8>>, acc) do
    Map.merge(acc, %{button_2: value})
  end

  # Proximity
  def map_packet(<<0x0b, 0x01, value::16>>, acc) do
    Map.merge(acc, %{proximity: value}) # Unit: cm
  end
  def map_packet(<<0x0b, 0x06, value::8>>, acc) do
    Map.merge(acc, %{proximity_percent: value}) # Unit: %
  end

  # Tracking
  def map_packet(<<0x0f, 0x01, value::16>>, acc) do
    Map.merge(acc, %{localisation_id: value})
  end

  # Indoor Localization
  def map_packet(<<0x12, 0x02, payload::binary>>, acc) do
    (for <<mac::binary-6, rssi::8-signed <- payload>>, do: {mac, rssi})
    |> Enum.with_index(1)
    |> Enum.reduce(acc, fn({{mac, rssi}, index}, acc) ->
      Map.merge(acc, %{
        "local_#{index}_mac" => Base.encode16(mac),
        "local_#{index}_rssi" => rssi,
      })
    end)
  end

  # GPS
  def map_packet(<<0x50, 0x01, value::signed-32>>, acc) do
    Map.merge(acc, %{gps_lat: value / 1000000})
  end
  def map_packet(<<0x50, 0x02, value::signed-32>>, acc) do
    Map.merge(acc, %{gps_lon: value / 1000000})
  end

  # Battery
  def map_packet(<<0x51, 0x01, value::8>>, acc) do
    Map.merge(acc, %{battery_voltage: value/10})
  end
  def map_packet(<<0x51, 0x02, value::8>>, acc) do
    Map.merge(acc, %{battery_indicator: case value do
      0x01 -> "FRESH"
      0x02 -> "FIT"
      0x03 -> "USEABLE"
      0x04 -> "REPLACE"
      _    -> "UNKOWN"
    end})
  end

  # Bluetooth SIG
  def map_packet(<<0x2A, 0x25, value::binary-6>>, acc) do
    Map.merge(acc, %{serial_number: Base.encode16(value)})
  end

  def map_packet({:error, error}, acc) do
    Map.merge(acc, %{parsing_error: error})
  end
  def map_packet(invalid, acc) do
    Map.merge(acc, %{invalid_packet_payload: Base.encode16(invalid)})
  end


  def parse_packets(<<>>, acc), do: acc
  def parse_packets(data, acc) do
    case next_packet(data) do
      {:ok, {packet, rest}} -> parse_packets(rest, acc ++ [packet])
      {:error, _} = error -> acc ++ [error]
    end
  end

  def next_packet(<<service_data_length, packet_payload::binary-size(service_data_length), rest::binary>>) do
    {:ok, {packet_payload, rest}}
  end
  def next_packet(_invalid), do: {:error, :invalid_payload}


  def fields do
    [
      %{
        "field" => "ambient_light",
        "display" => "Ambient Light",
        "unit" => "lux"
      },
      %{
        "field" => "temperature",
        "display" => "Temperature",
        "unit" => "C°"
      },
      %{
        "field" => "humidity",
        "display" => "Humidity",
        "unit" => "%"
      },
      %{
        "field" => "accelerate_x",
        "display" => "Accelerate-X",
        "unit" => "millig"
      },
      %{
        "field" => "accelerate_y",
        "display" => "Accelerate-Y",
        "unit" => "millig"
      },
      %{
        "field" => "accelerate_z",
        "display" => "Accelerate-Z",
        "unit" => "millig"
      },
      %{
        "field" => "button_1",
        "display" => "Button-1",
      },
      %{
        "field" => "button_2",
        "display" => "Button-2",
      },
      %{
        "field" => "proximity",
        "display" => "Proximity",
        "unit" => "cm"
      },
      %{
        "field" => "proximity_percent",
        "display" => "Proximity",
        "unit" => "%"
      },
      %{
        "field" => "ullage",
        "display" => "Ullage",
        "unit" => "%"
      },
      %{
        "field" => "localisation_id",
        "display" => "Localisation-ID",
      },
      %{
        "field" => "gps_lat",
        "display" => "GPS-Lat",
      },
      %{
        "field" => "gps_lon",
        "display" => "GPS-Lon",
      },
      %{
        "field" => "battery_voltage",
        "display" => "Battery",
        "unit" => "V"
      },
      %{
        "field" => "battery_indicator",
        "display" => "Battery Indicator",
      },
      %{
        "field" => "serial_number",
        "display" => "Serial Number",
      },
    ]
  end

  def tests() do
    [
      {
        :parse_hex,  "04010109C0", %{meta: %{frame_port: 1}}, %{ambient_light: 2496},
      },
      {
        :parse_hex,  "06020141C40000", %{meta: %{frame_port: 1}}, %{temperature: 24.5},
      },
      {
        :parse_hex,  "03030142", %{meta: %{frame_port: 1}}, %{humidity: 66}, # There was no example in documentation
      },
      {
        :parse_hex,  "0404010035", %{meta: %{frame_port: 1}}, %{accelerate_x: 53},
      },
      {
        :parse_hex,  "0404020000", %{meta: %{frame_port: 1}}, %{accelerate_y: 0},
      },
      {
        :parse_hex,  "0404030400", %{meta: %{frame_port: 1}}, %{accelerate_z: 1024},
      },
      {
        :parse_hex,  "040403FC00", %{meta: %{frame_port: 1}}, %{accelerate_z: -1024}, # This was not in documentation, they forgot to add a negative number.
      },
      {
        :parse_hex,  "03050100", %{meta: %{frame_port: 1}}, %{button_1: 0},
      },
      {
        :parse_hex,  "03050101", %{meta: %{frame_port: 1}}, %{button_1: 1},
      },
      {
        :parse_hex,  "040B0101F4", %{meta: %{frame_port: 1}}, %{proximity: 500, ullage: 0},
      },
      {
        :parse_hex,  "040F011234", %{meta: %{frame_port: 1}}, %{localisation_id: 4660}, # Missing example in docs.
      },
      {
        :parse_hex,  "06500102FFAC48", %{meta: %{frame_port: 1}}, %{gps_lat: 50.310216},
      },
      {
        :parse_hex,  "0351012D", %{meta: %{frame_port: 1}}, %{battery_voltage: 4.5},
      },
      {
        :parse_hex,  "03510201", %{meta: %{frame_port: 1}}, %{battery_indicator: "FRESH"},
      },
      {
        :parse_hex,  "082A250102A2BDAA11", %{meta: %{frame_port: 1}}, %{serial_number: "0102A2BDAA11"},
      },

      {
        :parse_hex,  "040101026306020141DD83F30351011D", %{meta: %{frame_port: 1}}, %{ambient_light: 611, battery_voltage: 2.9, temperature: 27.689428329467773},
      },

      {
        :parse_hex,  "040101005806020141B17FE8030301220351012103510201", %{meta: %{frame_port: 1}},
        %{
          ambient_light: 88,
          battery_indicator: "FRESH",
          battery_voltage: 3.3,
          humidity: 34,
          temperature: 22.187454223632813
        },
      },

      {
        :parse_hex,  "040B010089030B060B060201409F802E03510126", %{meta: %{frame_port: 1}},
        %{
          battery_voltage: 3.8,
          proximity: 137,
          proximity_percent: 11,
          temperature: 4.984396934509277,
          ullage: 31
        },
      },

      {
        :parse_hex,  "101202AC233F291662C2AC233F291667AC", %{meta: %{frame_port: 1}},
        %{
          "local_1_mac" => "AC233F291662",
          "local_1_rssi" => -62,
          "local_2_mac" => "AC233F291667",
          "local_2_rssi" => -84
        },
      },


      {
        :parse_hex,
        "040B0100B3030B060006020141DAAF1B03510126",
        %{meta: %{frame_port: 1}, device: %{fields: %{conbee: %{distance_zero_percent: 152, distance_hundred_percent: 25}}}},
        %{
          battery_voltage: 3.8,
          proximity: 179,
          proximity_percent: 0,
          temperature: 27.335500717163086,
          ullage: 0
        },
      },
    ]
  end
end
