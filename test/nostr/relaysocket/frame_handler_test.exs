defmodule Nostr.RelaySocket.FrameHandlerTest do
  use ExUnit.Case, async: true

  alias Nostr.RelaySocket.FrameHandler
  alias Nostr.Frames.Ok

  test "manage an OK frame" do
    frame = ~s(["OK","a806462fec12d934e452e1375a2401ef",true,"duplicate:"])
    subscriptions = [a806462fec12d934e452e1375a2401ef: self()]
    relay_url = "my.relay.social"

    :ok = FrameHandler.handle_text_frame(frame, subscriptions, relay_url, self())

    assert_receive {^relay_url, %Ok{persisted?: true, reason: "duplicate:"}}
  end
end
