defmodule Parser do
  use Platform.Parsing.Behaviour

  # ELEMENT IoT Parser for lobaro oskar v2 sensor. smart waste ultrasonic sensor
  # According to documentation provided by lobaro
  # if there is a profile named oscar one can set the fields amplitude and width
  # both need to be of type integer and are used as min value to be considered a valid reading
  # amplitude defaults to 100 and width to 50
  # if after filtering multiple values seem valid, a median is calculated

  # Changelog
  #   2019-04-04 []: Initial version.
  #   2019-04-04 [gw]: Added tests, updated fields


  def preloads() do
    [device: [profile_data: [:profile]]]
  end

  def parse(<<_fw_version::24, vbat::little-16, temp::little-16-signed>>, %{meta: %{frame_port: 1}}) do

    %{
      messagetype: "status",
      temperature: temp/10,
      battery: vbat/1000
    }
  end

  def parse(<<vbat::little-16, temp::little-16-signed, _res, data::binary >>, %{meta: %{frame_port: 2}} = meta) do
    min_width = get_min_width(meta)
    min_amplitude = get_min_amplitude(meta)
    readings = for << dist::little-32, tof_us::little-16, width, amplitude <- data >> do
                 %{distance1_mm: dist, tof_us: tof_us, width: width, amplitude: amplitude}
               end
               |> Enum.filter(fn
                    %{width: width, amplitude: amplitude} -> width >= min_width && amplitude >= min_amplitude
                  end)
               |> Enum.sort_by(fn %{distance1_mm: dist} -> dist end)

    num_readings = length(readings)

    cond do
      num_readings == 0 ->
        []
      rem(num_readings, 2) == 1 ->
        dist = readings
               |> Enum.at(div(num_readings, 2))
               |> get([:distance1_mm])
        %{
          temperature: temp/10,
          distance1_m: dist/1000,
          distance1_mm: dist
        }
      true ->
        one = readings
              |> Enum.at(div(num_readings, 2) - 1)
              |> get([:distance1_mm])
        two = readings
              |> Enum.at(div(num_readings, 2))
              |> get([:distance1_mm])
        dist = div(one + two, 2)
        %{
          temperature: temp/10,
          distance1_m: dist/1000,
          distance1_mm: dist
        }
    end
  end

  defp get_min_amplitude(meta) do
    get(meta, [:device, :fields, :oscar, :amplitude], 100)
  end

  defp get_min_width(meta) do
    get(meta, [:device, :fields, :oscar, :width], 50)
  end

  def fields() do
    [
      %{
        field: "messagetype",
        display: "Messagetype"
      },
      %{
        field: "battery",
        display: "Battery"
      },
      %{
        field: "temperature",
        display: "Temperature",
        unit: "°C"
      },
      %{
        field: "distance1_mm",
        display: "Distance (m)",
        unit: "mm"
      },
      %{
        field: "distance1_m",
        display: "Distance (mm)",
        unit: "m"
      }
    ]
  end

  def tests() do
    [
      {
        :parse_hex, "AC0DB40001CD010000E60A2369CD010000E60A2369", %{meta: %{frame_port: 2}, device: %{fields: %{oscar: %{amplitude: 100, width: 30}}}},
          %{
            temperature: 18.0,
            distance1_mm: 461,
            distance1_m: 0.461
          }
      },
      {
        :parse_hex, "AC0DB40001CD010000E60A2369CDF10000E60A2369CDF10000E60A2369", %{meta: %{frame_port: 2}, device: %{fields: %{oscar: %{amplitude: 100, width: 30}}}},
          %{
            temperature: 18.0,
            distance1_mm: 61901,
            distance1_m: 61.901,
          }
      },
      {
        :parse_hex, "AC0DB40001CD010000E60A2369CDF10000E60A2369CDF10000E60A2369CDF10000E60A2369", %{meta: %{frame_port: 2}, device: %{fields: %{oscar: %{amplitude: 100, width: 30}}}},
          %{
            temperature: 18.0,
            distance1_mm: 61901,
            distance1_m: 61.901,
          }
      }
    ]
  end
end