defmodule Parser do
  use Platform.Parsing.Behaviour

  require Logger

  # ELEMENT IoT Parser for NAS "Pulse + Analog Reader UM30x3" v0.5.0 and v0.7.0
  # Author NKlein
  # Link: https://www.nasys.no/product/lorawan-pulse-analog-reader/
  # Documentation:
  #   UM3023
  #     0.5.0: https://www.nasys.no/wp-content/uploads/Pulse-Analog-Reader_UM3023.pdf
  #     0.7.0: https://www.nasys.no/wp-content/uploads/Pulse_readeranalog_UM3023.pdf
  #   UM3033
  #     0.7.0: https://www.nasys.no/wp-content/uploads/Pulse_ReaderMbus_UM3033.pdf

  # Changelog
  #   2018-09-04 [jb]: Added tests. Handling Configuration request on port 49
  #   2019-05-07 [gw]: Updated with information from 0.7.0 document. Fix rssi and medium_type mapping.
  #   2019-05-07 [gw]: Also handling UM3033 devices.
  #   2019-05-17 [jb]: Added obis field for gas_in_liter. Added interpolation of values. Fixed boot message for v0.7.0.
  #   2019-05-22 [gw]: Adjusted fw version on boot message and also return status message from boot message as separate reading.


  # Flag if interpolated values for 0:00, 0:15, 0:30, 0:45, ... should be calculated
  # Default: true
  def interpolate?(), do: true
  # Minutes between interpolated values
  # Default: 15
  def interpolate_minutes(), do: 60

  # Name of timezone.
  # Default: "Europe/Berlin"
  def timezone(), do: "Europe/Berlin"



  defp add_obis([_|_] = readings, meta) do
    Enum.map(readings, &add_obis(&1, meta))
  end

  defp add_obis(%{"digital1_reporting_medium_type" => :gas_in_liter, :digital1_reporting => value} = reading, meta) do
    obis = "7-0:3.0.0"
    reading
    |> Map.put(:obis, obis)
    |> Map.put(obis, round_as_float(value / 1000)) # Convert liter to m3
    |> add_missing(meta)
  end
  defp add_obis(%{"digital2_reporting_medium_type" => :gas_in_liter, :digital2_reporting => value} = reading, meta) do
    obis = "7-0:3.0.0"
    reading
    |> Map.put(:obis, obis)
    |> Map.put(obis, round_as_float(value / 1000)) # Convert liter to m3
    |> add_missing(meta)
  end

  defp add_obis(%{} = data, _meta), do: data

  defp round_as_float(value) do
    Float.round(value / 1, 3)
  end

  defp add_missing(%{"7-0:3.0.0" => current_value} = data, meta) do

    if interpolate?() do

      obis = "7-0:3.0.0"
      current_measured_at = Map.get(meta, :transceived_at)
      last_reading_query = [obis: obis]

      case get_last_reading(meta, last_reading_query) do
        %{data: %{^obis => last_value}, measured_at: last_measured_at} ->

          readings = [
            {%{value: last_value}, [measured_at: last_measured_at]},
            {%{value: current_value}, [measured_at: current_measured_at]},
          ]
          |> TimeSeries.fill_gaps(
               fn datetime_a, datetime_b ->
                 # Calculate all tuples with x=nil between a and b where a value should be interpolated
                 interval = Timex.Interval.new(
                   from: datetime_a |> Timex.to_datetime(timezone()) |> datetime_add_to_multiple_of_minutes(interpolate_minutes()),
                   until: datetime_b,
                   left_open: false,
                   step: [minutes: interpolate_minutes()]
                 )
                 Enum.map(interval, &({nil, [measured_at: &1]}))
               end,
               :linear,
               x_access_path: [Access.elem(1), :measured_at],
               y_access_path: [Access.elem(0)],
               x_pre_calc_fun: &Timex.to_unix/1,
               x_post_calc_fun: &Timex.to_datetime/1,
               y_pre_calc_fun: fn %{value: value} -> value end,
               y_post_calc_fun: &(%{value: &1, _interpolated: true})
             )
          |> Enum.filter(fn ({data, _meta}) -> Map.get(data, :_interpolated, false) end)
          |> Enum.map(fn {%{value: value}, reading_meta} ->
            value = round_as_float(value)
            {
              %{
                :obis => obis,
                obis => value,
              },
              reading_meta
            }
          end)

          [data] ++ readings

        nil ->
          Logger.info("No result for get_last_reading(#{inspect last_reading_query})")
          [data]

        invalid_prev_reading ->
          Logger.warn("Could not add_missing() because of invalid previous reading: #{inspect invalid_prev_reading}")
          [data]
      end

    else
      []
    end
  end
  defp add_missing(current_data, _meta), do: current_data

  # Will shift 2019-04-20 12:34:56 to   2019-04-20 12:45:00
  defp datetime_add_to_multiple_of_minutes(%DateTime{} = dt, minutes) do
    minute_seconds = minutes * 60
    rem = rem(DateTime.to_unix(dt), minute_seconds)
    Timex.shift(dt, seconds: (minute_seconds - rem))
  end

  # Status Message
  def parse(<<settings::binary-1, battery::unsigned, temp::signed, rssi::signed, interface_status::binary>>, %{meta: %{frame_port:  24}} = meta) do
    %{
      battery: battery,
      temp: temp,
      rssi: rssi * -1,
    }
    |> parse_reporting(settings, interface_status)
    |> add_obis(meta)
  end

  # Status Message
  def parse(<<settings::binary-1, interface_status::binary>>, %{meta: %{frame_port:  25}} = meta) do
    %{}
    |> parse_reporting(settings, interface_status)
    |> add_obis(meta)
  end

  # Boot Message
  def parse(<<0x00, serial::4-binary, firmware::3-binary, rest::binary>>, %{meta: %{frame_port:  99}}) do
    <<major::8, minor::8, patch::8>> = firmware
    {%{
      type: :boot,
      serial: Base.encode16(serial),
      firmware: "#{major}.#{minor}.#{patch}",
    }, rest}
    |> case do
      {reading, <<reset_reason, rest::binary>>} ->
        reset_msg = Map.get(%{0x02 => :watchdog_reset, 0x04 => :soft_reset, 0x10 => :normal_magnet}, reset_reason, :unknown)
        {Map.put(reading, :reset_reason, reset_msg), rest}
      default ->
        default
    end
    |> case do
      {reading, <<battery_info>>} ->
        battery_voltage = Map.get(%{0x1 => "3.0V", 0x2 => "3.6V"}, battery_info, :unknown)
        {Map.put(reading, :battery_voltage, battery_voltage), rest}
      default ->
        default
    end
    |> Kernel.elem(0)
  end
  # Shutdown Message
  def parse(<<0x01>>, %{meta: %{frame_port:  99}}) do
    %{
      type: :shutdown,
    }
  end
  def parse(<<0x01, reason, status_message::binary>>, %{meta: %{frame_port:  99}}) do
    reason = Map.get(%{0x02 => :hardware_error, 0x31 => :user_magnet, 0x32 => :user_dfu}, reason, :unknown)
    [
      %{
        type: :shutdown,
        reason: reason,
      },
      parse(status_message, %{meta: %{frame_port: 25}})
    ]
  end
  # Error Code Message
  def parse(<<0x10, error_code>>, %{meta: %{frame_port:  99}}) do
    %{
      type: :error,
      error_code: error_code,
    }
  end

  # Configuration Message
  def parse(_payload, %{meta: %{frame_port:  49}}) do
    %{
      type: :config_req,
    }
  end

  # MBus connect Message
  def parse(<<0x01, packet_info::binary-1, rest::binary>>, %{meta: %{frame_port: 53}}) do
    <<only_drh::1, mbus_fixed_header::1, _rfu::2, packets_to_follow::1, packet_number::3>> = packet_info
    packet_info_map = %{
      type: :mbus_connect,
      packet_number: packet_number,
      packets_to_follow: (packets_to_follow == 1),
      mbus_fixed_header: sent_or_not(mbus_fixed_header),
      only_drh: (only_drh == 1),
    }

    mbus_fixed = if mbus_fixed_header == 1 do
      <<bcd_ident_number::little-32, manufacturer_id::binary-2, sw_version::binary-1, medium::binary-1, access_number:: binary-1, status::binary-1, signature::binary-2, _drh_bytes::binary>> = rest

      %{
        bcd_ident_number: Base.encode16(<<bcd_ident_number::32>>),
        manufacturer_id: Base.encode16(manufacturer_id),
        sw_version: Base.encode16(sw_version),
        medium: Base.encode16(medium),
        access_number: Base.encode16(access_number),
        status: Base.encode16(status),
        signature: Base.encode16(signature),
      }
    else
      %{}
    end

    Map.merge(packet_info_map, mbus_fixed)
  end

  # Catchall for any other message.
  def parse(payload, meta) do
    Logger.warn("Could not parse payload #{inspect payload} with frame_port #{inspect get_in(meta, [:meta, :frame_port])}")
    []
  end

  defp parse_reporting(map, <<settings::binary-1>>, interface_status) do
    <<_rfu::1, user_triggered::1, mbus::1, ssi::1, analog2_reporting::1, analog1_reporting::1, digital2_reporting::1, digital1_reporting::1>> = settings
    settings_map = %{
      user_triggered: (1 == user_triggered),
      mbus: (1 == mbus),
      ssi: (1 == ssi)
    }
    
    [digital1_reporting: digital1_reporting, digital2_reporting: digital2_reporting, analog1_reporting: analog1_reporting, analog2_reporting: analog2_reporting, mbus_reporting: mbus]
    |> Enum.filter(fn {_,y} -> y == 1 end)
    |> Enum.map(&elem(&1,0))
    |> parse_single_reporting(Map.merge(settings_map, map), interface_status)
  end

  defp parse_single_reporting([type | _more_types], map, <<status::binary-1, mbus_status, dr::binary>>) when type in [:mbus_reporting] do
    <<_rfu::4, parameter::4>> = status
    mbus_map = %{
      mbus_parameter: mbus_parameter(parameter),
      mbus_status: mbus_status,
    }

    [Map.merge(mbus_map, map)] ++ filter_and_flatmap_mbus_data(dr)
  end

  defp parse_single_reporting([type | more_types], map, <<settings::8, counter::little-32, rest::binary>>) when type in [:digital1_reporting, :digital2_reporting] do
    <<medium_type::4, _rfu::1, trigger_alert::1, trigger_mode::1, value_high::1>> = <<settings>>
    result = %{
      type => counter,
      "#{type}_medium_type" => medium_type(medium_type),
      "#{type}_trigger_alert" => %{0=>:ok, 1=>:alert}[trigger_alert],
      "#{type}_trigger_mode2" => %{0=>:disabled, 1=>:enabled}[trigger_mode],
      "#{type}_value_during_reporting" => %{0=>:low, 1=>:high}[value_high],
    }

    parse_single_reporting(more_types, Map.merge(map, result), rest)
  end

  # analog: both current (instant) and average value are sent
  defp parse_single_reporting([type | more_types], map, <<status_settings::binary-1, rest::binary>>) when type in [:analog1_reporting, :analog2_reporting] do
    <<average_flag::1, instant_flag::1, _rfu::4, _thresh_alert::1, mode::1>> = status_settings

    {new_map, new_rest} =
      {map, rest}
      |> parse_analog_value("#{type}_current_value", instant_flag)
      |> parse_analog_value("#{type}_average_value", average_flag)

    result_map = Map.put(new_map, "#{type}_mode", %{0 => "0..10V", 1 => "4..20mA"}[mode])
    parse_single_reporting(more_types, result_map, new_rest)
  end

  defp parse_single_reporting(_, map, _) do
    map
  end

  defp parse_analog_value({map, <<value::float-little-32, rest::binary>>}, key, 1) do
    {
      Map.put(map, key, value),
      rest
    }
  end
  defp parse_analog_value({map, rest}, _, 0), do: {map, rest}

  defp filter_and_flatmap_mbus_data(mbus_data) do
    mbus_data
    |> LibWmbus.Dib.parse_dib()
    |> Enum.map(fn
      %{data: data} = map ->
        Map.merge(map, data)
        |> Map.delete(:data)
    end)
    |> Enum.map(fn
      %{desc: "error codes", value: v} = map ->
        Map.merge(map, %{"error codes" => v, :unit => ""})
        |> Map.drop([:desc, :value])
      %{desc: d = "energy", value: v, unit: "Wh"} = map ->
        Map.merge(map, %{d => Float.round(v / 1000, 3), :unit => "kWh"})
        |> Map.drop([:desc, :value])
      %{desc: d, value: v} = map ->
        Map.merge(map, %{d => v})
        |> Map.drop([:desc, :value])
    end)
  end

  defp mbus_parameter(0x00), do: :ok
  defp mbus_parameter(0x01), do: :nothing_requested
  defp mbus_parameter(0x02), do: :bus_unpowered
  defp mbus_parameter(0x03), do: :no_response
  defp mbus_parameter(0x04), do: :empty_response
  defp mbus_parameter(0x05), do: :invalid_data
  defp mbus_parameter(_), do: :rfu

  defp medium_type(0x00), do: :not_available
  defp medium_type(0x01), do: :pulses
  defp medium_type(0x02), do: :water_in_liter
  defp medium_type(0x03), do: :electricity_in_wh
  defp medium_type(0x04), do: :gas_in_liter
  defp medium_type(0x05), do: :heat_in_wh
  defp medium_type(_),    do: :rfu

  defp sent_or_not(0), do: :not_sent
  defp sent_or_not(1), do: :sent
  defp sent_or_not(_), do: :unknown

  def tests() do
    [
      {
        :parse_hex,  "03E6172C50000000002000000000", %{meta: %{frame_port: 24}},  %{
          :battery => 230,
          :digital1_reporting => 0,
          :digital2_reporting => 0,
          :mbus => false,
          :rssi => -44,
          :ssi => false,
          :temp => 23,
          :user_triggered => false,
          "digital1_reporting_medium_type" => :heat_in_wh,
          "digital1_reporting_trigger_alert" => :ok,
          "digital1_reporting_trigger_mode2" => :disabled,
          "digital1_reporting_value_during_reporting" => :low,
          "digital2_reporting_medium_type" => :water_in_liter,
          "digital2_reporting_trigger_alert" => :ok,
          "digital2_reporting_trigger_mode2" => :disabled,
          "digital2_reporting_value_during_reporting" => :low
        },
      },
      { # Example Payload for UM3023 from docs v0.7.0
        :parse_hex, "0FF61A4B120100000010C40900004039C160404140C9D740", %{meta: %{frame_port: 24}}, %{
          :battery => 246,
          :digital1_reporting => 1,
          :digital2_reporting => 2500,
          :temp => 26,
          :rssi => -75,
          :mbus => false,
          :ssi => false,
          :user_triggered => false,
          "analog1_reporting_current_value" => 3.511793375015259,
          "analog1_reporting_mode" => "0..10V",
          "analog2_reporting_current_value" => 6.743316650390625,
          "analog2_reporting_mode" => "4..20mA",
          "digital1_reporting_medium_type" => :pulses,
          "digital1_reporting_trigger_alert" => :ok,
          "digital1_reporting_trigger_mode2" => :enabled,
          "digital1_reporting_value_during_reporting" => :low,
          "digital2_reporting_medium_type" => :pulses,
          "digital2_reporting_trigger_alert" => :ok,
          "digital2_reporting_trigger_mode2" => :disabled,
          "digital2_reporting_value_during_reporting" => :low,
        }
      },
      # Commented the following test, as it is using a library that is not publicly available yet
      { # Example Payload for UM3033 from docs v0.7.0
        :parse_hex, "63F51B361000000000100000000000000B2D4700009B102D5800000C0616160000046D0A0E5727", %{meta: %{frame_port: 24}}, [
          %{
            :battery => 245,
            :digital1_reporting => 0,
            :digital2_reporting => 0,
            :mbus => true,
            :mbus_parameter => :ok,
            :mbus_status => 0,
            :rssi => -54,
            :ssi => false,
            :temp => 27,
            :user_triggered => true,
            "digital1_reporting_medium_type" => :pulses,
            "digital1_reporting_trigger_alert" => :ok,
            "digital1_reporting_trigger_mode2" => :disabled,
            "digital1_reporting_value_during_reporting" => :low,
            "digital2_reporting_medium_type" => :pulses,
            "digital2_reporting_trigger_alert" => :ok,
            "digital2_reporting_trigger_mode2" => :disabled,
            "digital2_reporting_value_during_reporting" => :low
          },
          %{
            function_field: :current_value,
            memory_address: 0,
            power: 4700,
            sub_device: 0,
            tariff: 0,
            unit: "W"
          },
          %{
            function_field: :max_value,
            memory_address: 0,
            power: 5800,
            sub_device: 0,
            tariff: 1,
            unit: "W"
          },
          %{
            energy: 1616000,
            function_field: :current_value,
            memory_address: 0,
            sub_device: 0,
            tariff: 0,
            unit: "Wh"
          },
          %{
            datetime: ~N[2018-07-23 14:10:00],
            function_field: :current_value,
            memory_address: 0,
            sub_device: 0,
            tariff: 0,
            unit: ""
          }
        ]
      },
      {
        :parse_hex,  "0350000000002006000000", %{meta: %{frame_port: 25}},  %{
          :digital1_reporting => 0,
          :digital2_reporting => 6,
          :mbus => false,
          :ssi => false,
          :user_triggered => false,
          "digital1_reporting_medium_type" => :heat_in_wh,
          "digital1_reporting_trigger_alert" => :ok,
          "digital1_reporting_trigger_mode2" => :disabled,
          "digital1_reporting_value_during_reporting" => :low,
          "digital2_reporting_medium_type" => :water_in_liter,
          "digital2_reporting_trigger_alert" => :ok,
          "digital2_reporting_trigger_mode2" => :disabled,
          "digital2_reporting_value_during_reporting" => :low
        },
      },

      {
        :parse_hex,  "0340060000005000000000", %{meta: %{frame_port: 25}},  [
          %{
            :digital1_reporting => 6,
            :digital2_reporting => 0,
            :mbus => false,
            :obis => "7-0:3.0.0",
            :ssi => false,
            :user_triggered => false,
            "7-0:3.0.0" => 0.006,
            "digital1_reporting_medium_type" => :gas_in_liter,
            "digital1_reporting_trigger_alert" => :ok,
            "digital1_reporting_trigger_mode2" => :disabled,
            "digital1_reporting_value_during_reporting" => :low,
            "digital2_reporting_medium_type" => :heat_in_wh,
            "digital2_reporting_trigger_alert" => :ok,
            "digital2_reporting_trigger_mode2" => :disabled,
            "digital2_reporting_value_during_reporting" => :low
          }
        ],
      },

      {
        :parse_hex,
        "0340060000005000000000",
        %{
          meta: %{frame_port: 25},
          transceived_at: test_datetime("2019-01-01T12:34:56Z"),
          _last_reading_map: %{
            [obis: "7-0:3.0.0"] => %{measured_at: test_datetime("2019-01-01T10:34:11Z"), data: %{:obis => "7-0:3.0.0", "7-0:3.0.0" => 0.003}},
          },
        },
        [
          %{
          :digital1_reporting => 6,
          :digital2_reporting => 0,
          :mbus => false,
          :obis => "7-0:3.0.0",
          :ssi => false,
          :user_triggered => false,
          "7-0:3.0.0" => 0.006,
          "digital1_reporting_medium_type" => :gas_in_liter,
          "digital1_reporting_trigger_alert" => :ok,
          "digital1_reporting_trigger_mode2" => :disabled,
          "digital1_reporting_value_during_reporting" => :low,
          "digital2_reporting_medium_type" => :heat_in_wh,
          "digital2_reporting_trigger_alert" => :ok,
          "digital2_reporting_trigger_mode2" => :disabled,
          "digital2_reporting_value_during_reporting" => :low
          },
          {%{:obis => "7-0:3.0.0", "7-0:3.0.0" => 0.004}, [measured_at: test_datetime("2019-01-01 11:00:00Z")]},
          {%{:obis => "7-0:3.0.0", "7-0:3.0.0" => 0.005}, [measured_at: test_datetime("2019-01-01 12:00:00Z")]}
        ],
      },

      { # Example Payload from docs 0.7.0
        :parse_hex, "0F12010000001000000000C0DA365C400B7E5E40C140C9D740DC73D940", %{meta: %{frame_port: 25}}, %{
          :digital1_reporting => 1,
          :digital2_reporting => 0,
          :mbus => false,
          :ssi => false,
          :user_triggered => false,
          "analog1_reporting_current_value" => 3.440847873687744,
          "analog1_reporting_average_value" => 3.47644305229187,
          "analog1_reporting_mode" => "0..10V",
          "analog2_reporting_current_value" => 6.743316650390625,
          "analog2_reporting_average_value" => 6.795392990112305,
          "analog2_reporting_mode" => "4..20mA",
          "digital1_reporting_medium_type" => :pulses,
          "digital1_reporting_trigger_alert" => :ok,
          "digital1_reporting_trigger_mode2" => :enabled,
          "digital1_reporting_value_during_reporting" => :low,
          "digital2_reporting_medium_type" => :pulses,
          "digital2_reporting_trigger_alert" => :ok,
          "digital2_reporting_trigger_mode2" => :disabled,
          "digital2_reporting_value_during_reporting" => :low,
        }
      },
      {
        :parse_hex,  "00D002A005000357020000803F27020000803F", %{meta: %{frame_port: 49}},  %{type: :config_req},
      },
      {
        :parse_hex, "01C888020969A732070415000000097409700C060C140B2D0B3B0B5A0B5E0B620C788910713C220C220C268C9010069B102D", %{meta: %{frame_port: 53}}, %{
          :type => :mbus_connect,
          :packet_number => 0,
          :packets_to_follow => true,
          :mbus_fixed_header => :sent,
          :only_drh => true,
          :bcd_ident_number => "69090288",
          :manufacturer_id => "A732",
          :sw_version => "07",
          :medium => "04",
          :access_number => "15",
          :status => "00",
          :signature => "0000"
        }
      },
      {
        :parse_hex, "01819B103B9B105A9B105E9410AD6F9410BB6F9410DA6F9410DE6F4C064C147C224C26CC901006DB102DDB103BDB105ADB105E848F0F6D046D", %{meta: %{frame_port: 53}}, %{
          :type => :mbus_connect,
          :packet_number => 1,
          :packets_to_follow => false,
          :mbus_fixed_header => :not_sent,
          :only_drh => true
        }
      },
      {
        :parse_hex,  "01", %{meta: %{frame_port: 99}}, %{type: :shutdown},
      },
      {
        :parse_hex,  "1001", %{meta: %{frame_port: 99}}, %{error_code: 1, type: :error},
      },
      {
        :parse_hex,  "00D701164C0007081002", %{meta: %{frame_port: 99}},  %{
          battery_voltage: "3.6V",
          firmware: "0.7.8",
          reset_reason: :normal_magnet,
          serial: "D701164C",
          type: :boot
        },
      },
      {
        :parse_hex,  "0131033A0B7C10000000001000000000", %{meta: %{frame_port: 99}}, [
          %{
            reason: :user_magnet,
            type: :shutdown,
          },
          %{
            :digital1_reporting => 1080331,
            :digital2_reporting => 1048576,
            :mbus => false,
            :ssi => false,
            :user_triggered => false,
            "digital1_reporting_medium_type" => :electricity_in_wh,
            "digital1_reporting_trigger_alert" => :ok,
            "digital1_reporting_trigger_mode2" => :enabled,
            "digital1_reporting_value_during_reporting" => :low,
            "digital2_reporting_medium_type" => :not_available,
            "digital2_reporting_trigger_alert" => :ok,
            "digital2_reporting_trigger_mode2" => :disabled,
            "digital2_reporting_value_during_reporting" => :low,
          }
        ]
      },
      {
        :parse_hex,  "00CA021C4E000722100200", %{meta: %{frame_port: 99}}, %{
          firmware: "0.7.34",
          reset_reason: :normal_magnet,
          serial: "CA021C4E",
          type: :boot
        },
      },
      {
        :parse_hex, "211000000000000406A71140000259C525025D5B1802616A0D0414181E2201043C68010000042D84050000143CBF010000142DFC08000082086C9F2C", %{meta: %{frame_port: 25}}, [
          %{
            :digital1_reporting => 0,
            :mbus => true,
            :mbus_parameter => :ok,
            :mbus_status => 4,
            :ssi => false,
            :user_triggered => false,
            "digital1_reporting_medium_type" => :pulses,
            "digital1_reporting_trigger_alert" => :ok,
            "digital1_reporting_trigger_mode2" => :disabled,
            "digital1_reporting_value_during_reporting" => :low
          },
          %{
            function_field: :current_value,
            memory_address: 0,
            operation_time: 41529532088384,
            sub_device: 0,
            tariff: 0,
            unit: "days with unknown vife"
          },
          %{
            function_field: :current_value,
            memory_address: 0,
            return_temperature: 62.35,
            sub_device: 0,
            tariff: 0,
            unit: "°C"
          },
          %{
            function_field: :current_value,
            memory_address: 0,
            sub_device: 0,
            tariff: 0,
            temperature_difference: 34.34,
            unit: "K"
          },
          %{
            function_field: :current_value,
            memory_address: 0,
            sub_device: 0,
            tariff: 0,
            unit: "m³",
            volume: 190131.44
          },
          %{
            flow: 3.6,
            function_field: :current_value,
            memory_address: 0,
            sub_device: 0,
            tariff: 0,
            unit: "m³/h"
          },
          %{
            function_field: :current_value,
            memory_address: 0,
            power: 141200,
            sub_device: 0,
            tariff: 0,
            unit: "W"
          },
          %{
            flow: 4.47,
            function_field: :max_value,
            memory_address: 0,
            sub_device: 0,
            tariff: 0,
            unit: "m³/h"
          },
          %{
            function_field: :max_value,
            memory_address: 0,
            power: 230000,
            sub_device: 0,
            tariff: 0,
            unit: "W"
          },
          %{
            date: Date.from_erl!({2020, 12, 31}),
            function_field: :current_value,
            memory_address: 16,
            sub_device: 0,
            tariff: 0,
            unit: ""
          }
        ]
      },
      {
        :parse_hex, "200004063E0000000413E410000002591409025DA408042D00000000043B00000000", %{meta: %{frame_port: 25}}, [
          %{
            mbus: true,
            mbus_parameter: :ok,
            mbus_status: 4,
            ssi: false,
            user_triggered: false
          },
          %{
            flow: -30704654090240,
            function_field: :current_value,
            memory_address: 0,
            sub_device: 0,
            tariff: 0,
            unit: "m³/h"
          },
          %{
            energy: 0.0,
            function_field: :max_value,
            memory_address: 0,
            sub_device: 0,
            tariff: 0,
            unit: "Wh"
          },
          %{
            energy: 0.0,
            function_field: :current_value,
            memory_address: 0,
            sub_device: 0,
            tariff: 0,
            unit: "Wh"
          },
          %{
            function_field: :max_value,
            memory_address: 1,
            sub_device: 0,
            tariff: 0,
            unit: "m³",
            volume: 0.09
          },
          %{
            function_field: :current_value,
            memory_address: 0,
            return_temperature: 22.12,
            sub_device: 0,
            tariff: 0,
            unit: "°C"
          },
          %{
            function_field: :current_value,
            memory_address: 0,
            power: 0,
            sub_device: 0,
            tariff: 0,
            unit: "W"
          },
          %{
            flow: 0.0,
            function_field: :current_value,
            memory_address: 0,
            sub_device: 0,
            tariff: 0,
            unit: "m³/h"
          }
        ]
      },
    ]
  end

  # Helper for testing
  defp test_datetime(iso8601) do
    {:ok, datetime, _} = DateTime.from_iso8601(iso8601)
    datetime
  end

end
