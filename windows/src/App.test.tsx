import { render, screen } from "@testing-library/react";
import { App } from "./App";

test("the shell renders", () => {
  render(<App />);
  expect(screen.getByRole("heading", { name: "OpenWispr" })).toBeDefined();
});
