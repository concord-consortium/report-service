import React from "react";
import Icon from "../assets/concord.png";

import "./header.scss";

export const Header: React.FC = () => {
  return (
    <div className="header">
      <img src={Icon}/>
      Researcher Reports
    </div>
  );
};
