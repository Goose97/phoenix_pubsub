defmodule Phoenix.PubSub.PG2 do
  @moduledoc """
  Phoenix PubSub adapter based on `:pg`/`:pg2`.

  It runs on Distributed Erlang and is the default adapter.
  """

  @behaviour Phoenix.PubSub.Adapter
  use Supervisor

  ## Adapter callbacks

  @impl true
  def node_name(_), do: node()

  @impl true
  def broadcast(adapter_name, topic, message, dispatcher) do
    case pg_members(group(adapter_name)) do
      {:error, {:no_such_group, _}} ->
        {:error, :no_such_group}

      pids ->
        message = forward_to_local(topic, message, dispatcher)

        for pid <- pids, node(pid) != node() do
          send(pid, message)
        end

        :ok
    end
  end

  @impl true
  def direct_broadcast(adapter_name, node_name, topic, message, dispatcher) do
    send({group(adapter_name), node_name}, {:forward_to_local, topic, message, dispatcher})
    :ok
  end

  defp forward_to_local(topic, message, dispatcher) do
    {:forward_to_local, topic, message, dispatcher}
  end

  defp group(adapter_name) do
    groups = :persistent_term.get(adapter_name)
    # group_index = :erlang.phash2(self(), tuple_size(groups))

    # Chỗ này viết để support các node chưa chuyển sang dùng PubSub mới
    group_index = 0
    elem(groups, group_index)
  end

  if Code.ensure_loaded?(:pg) do
    defp pg_members(group) do
      :pg.get_members(Phoenix.PubSub, group)
    end
  else
    defp pg_members(group) do
      :pg2.get_members({:phx, group})
    end
  end

  ## Supervisor callbacks

  @doc false
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    pool_size = Keyword.get(opts, :pool_size, 1)
    adapter_name = Keyword.fetch!(opts, :adapter_name)
    Supervisor.start_link(__MODULE__, {name, adapter_name, pool_size}, name: adapter_name)
  end

  @impl true
  def init({name, adapter_name, pool_size}) do
    groups =
      for number <- 1..pool_size do
        :"#{adapter_name}_#{number}"
      end

    groups = [name] ++ groups
    :persistent_term.put(adapter_name, List.to_tuple(groups))

    children =
      for group <- groups do
        Supervisor.child_spec({Phoenix.PubSub.PG2Worker, {name, group}}, id: group)
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Phoenix.PubSub.PG2Worker do
  @moduledoc false
  use GenServer

  @doc false
  def start_link({name, group}) do
    # Đoạn này viết thế này để tránh việc trùng tên GenServer với supervisor
    gen_server_name = if name == group, do: Module.concat(name, Server), else: group
    GenServer.start_link(__MODULE__, {name, group}, name: gen_server_name)
  end

  @impl true
  def init({name, group}) do
    :ok = pg_join(group)
    {:ok, name}
  end

  @impl true
  def handle_info({:forward_to_local, topic, message, dispatcher}, pubsub) do
    Phoenix.PubSub.local_broadcast(pubsub, topic, message, dispatcher)
    {:noreply, pubsub}
  end

  @impl true
  # Message PubSub từ version cũ
  def handle_info({:forward_to_local, _fastlane, _from, topic, message}, pubsub) do
    Phoenix.PubSub.local_broadcast(pubsub, topic, message, Phoenix.PubSub)
    {:noreply, pubsub}
  end

  @impl true
  def handle_info(message, pubsub) do
    IO.inspect(message, label: "UNCAUGHT BROADCAST MESSAGE")
    {:noreply, pubsub}
  end

  if Code.ensure_loaded?(:pg) do
    defp pg_join(group) do
      :ok = :pg.join(Phoenix.PubSub, group, self())
    end
  else
    defp pg_join(group) do
      namespace = {:phx, group}
      :ok = :pg2.create(namespace)
      :ok = :pg2.join(namespace, self())
      :ok
    end
  end
end
