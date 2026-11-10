local restored_boxes = {}

local function valid_box(box)
    return type(box) == "table"
        and type(box.x) == "number" and type(box.y) == "number"
        and type(box.w) == "number" and box.w > 0
        and type(box.h) == "number" and box.h > 0
end

function _G.HWE_SESSION_RESTORE(data)
    restored_boxes = {}
    for id, box in pairs(data.boxes or {}) do
        if valid_box(box) then
            restored_boxes[tostring(id)] = box
        end
    end
    for _, workspace in ipairs(data.workspaces or {}) do
        hl.workspace_rule({
            workspace = workspace.name,
            monitor = workspace.monitor,
            layout = "hwe-session",
        })
    end
    return true
end

hl.layout.register("hwe-session", {
    recalculate = function(ctx)
        for _, target in ipairs(ctx.targets) do
            local window = target.window
            local box = window and restored_boxes[tostring(window.stable_id)]
            if box then
                target:place(box)
            elseif valid_box(target.box) then
                target:place(target.box)
            else
                target:place(ctx.area)
            end
        end
    end,
})
