const {
  SceneTeamCooperationHandler,
} = require("Game/Module/Battle/Cooperation/CooperationHandler/SceneTeamCooperationHandler.js");
const SceneTeamController_1 = require("../Game/Module/SceneTeam/SceneTeamController.js");
const SceneTeamDefine_1 = require("../Game/Module/SceneTeam/SceneTeamDefine.js");
const ScrollingTipsController_1 = require("Game/Module/ScrollingTips/ScrollingTipsController.js");
const InputDistributeController_1 = require("../Game/Ui/InputDistribute/InputDistributeController.js");
const InputMappingsDefine_1 = require("../Game/Ui/InputDistribute/InputMappingsDefine.js");
const ControllerHolder_1 = require("../Game/Manager/ControllerHolder.js");

const CONTROLLER_TYPE = "{CONTROLLER_TYPE}";

SceneTeamCooperationHandler.prototype.Trigger = function (e, r) {
  var r_EntityHandle = r.EntityHandle;
  let n = r_EntityHandle.Entity.GetComponent(109).IsInQte;
  var r_EntityHandle =
    r_EntityHandle.Entity.CheckGetComponent(104).IsChangeRoleCoolDown();
  if (!n) {
    if (CONTROLLER_TYPE !== "2" && r_EntityHandle) {
      if (CONTROLLER_TYPE === "0")
        ScrollingTipsController_1.ScrollingTipsController.ShowTipsById(
          "EditBattleTeamInCD",
        );

      return false;
    }
    n = e.EntityHandle.Entity.GetComponent(222);
    if (n.HasTag(-2044964178) && n.HasAnyTag(SceneTeamDefine_1.beHitTagList)) {
      if (Log_1.Log.CheckInfo()) {
        Log_1.Log.Info("SceneTeam", 48, "被击硬直时间无法换人", [
          "roleId",
          e.GetConfigId,
        ]);
      }

      return false;
    }
  }

  const open_photo_mode = () => {
    ControllerHolder_1.ControllerHolder.PhotographController.TryOpenPhotograph(
      0,
    );
  };

  if (e.GetConfigId === 8004) {
    InputDistributeController_1.InputDistributeController.UnBindAction(
      InputMappingsDefine_1.actionMappings.UI键盘T手柄Y,
      open_photo_mode,
    );
  }
  if (r.GetConfigId === 8004) {
    InputDistributeController_1.InputDistributeController.BindAction(
      InputMappingsDefine_1.actionMappings.UI键盘T手柄Y,
      open_photo_mode,
    );
  }

  SceneTeamController_1.SceneTeamController.RequestChangeRole(
    r.GetCreatureDataId(),
    {
      FilterSameRole: true,
      GoDownWaitSkillEnd: true,
      ForceInheritTransform: false,
    },
  );

  return true;
};
